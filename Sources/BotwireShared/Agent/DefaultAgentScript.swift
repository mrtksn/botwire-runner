//
//  DefaultAgentScript.swift
//  BotwireShared
//
//  The default JS AgentBlock script — the built-in agent orchestration loop.
//  Shared across iOS, macOS, Android, and Linux. No platform dependencies.
//

import Foundation

public enum DefaultAgentScript {
    /// The JS source code for the default agent orchestration loop.
    public static let source: String = #"""
    // Default BotEngine AgentBlock
    // This script implements the standard agent orchestration loop.
    // It uses Botwire.config, Botwire.stream, Botwire.tools, and Botwire.agent
    // to drive an LLM through tool-calling iterations.
    //
    // Context compaction: when input token usage crosses 70% of the budget,
    // the middle portion of messages[] is structurally compressed into a
    // summary system message. The system prompt (index 0), the original user
    // objective (index 1), and the last 3 tool-call turns are always kept verbatim.

    // ---------------------------------------------------------------------------
    // Context compaction
    // ---------------------------------------------------------------------------

    // Groups a flat messages[] array (after index 0+1) into logical turns.
    // Each turn = one assistant message + all its following tool results
    // + any trailing system reminder messages.
    function groupIntoTurns(messages) {
      const rest = messages.slice(2); // skip system(0) and user(1)
      const turns = [];
      let i = 0;
      while (i < rest.length) {
        const msg = rest[i];
        if (msg.role === 'assistant') {
          const turn = { assistant: msg, toolResults: [], trailing: [] };
          i++;
          while (i < rest.length && rest[i].role === 'tool') {
            turn.toolResults.push(rest[i]);
            i++;
          }
          while (i < rest.length && rest[i].role === 'system') {
            turn.trailing.push(rest[i]);
            i++;
          }
          turns.push(turn);
        } else {
          i++; // orphaned message — skip
        }
      }
      return turns;
    }

    // Compacts messages[] when approaching the token budget.
    // Returns a new (possibly shorter) messages array.
    // Invariants:
    //   - messages[0] (system prompt + context + skills) is always pinned
    //   - messages[1] (original user objective) is always pinned
    //   - The last KEEP_RECENT_TURNS turns are always kept verbatim
    //   - All older turns are replaced by a single compact summary system message
    function compactMessages(messages, maxInputTokens, totalInputTokens) {
      const COMPACT_THRESHOLD  = 0.70; // trigger at 70% of budget
      const KEEP_RECENT_TURNS  = 3;    // verbatim tail turns to preserve
      const TOOL_RESULT_PREVIEW = 200; // max chars per tool result in summary

      if (totalInputTokens < maxInputTokens * COMPACT_THRESHOLD) return messages;
      if (messages.length < 4) return messages;

      const systemMsg = messages[0];
      const userMsg   = messages[1];

      const turns = groupIntoTurns(messages);
      if (turns.length <= KEEP_RECENT_TURNS) return messages;

      const toSummarize = turns.slice(0, turns.length - KEEP_RECENT_TURNS);
      const toKeep      = turns.slice(turns.length - KEEP_RECENT_TURNS);

      // Build a concise, scannable summary of the older turns
      const summaryLines = ['[Earlier actions — compacted to preserve context window:]'];
      for (let t = 0; t < toSummarize.length; t++) {
        const turn = toSummarize[t];
        summaryLines.push('Turn ' + (t + 1) + ':');

        if (turn.assistant.tool_calls && turn.assistant.tool_calls.length > 0) {
          for (const tc of turn.assistant.tool_calls) {
            const name = tc.function ? tc.function.name : 'unknown';
            let args = '';
            try {
              const parsed = JSON.parse(tc.function ? tc.function.arguments : '{}');
              const keys = Object.keys(parsed).slice(0, 3);
              args = keys.map(k => k + '=' + String(parsed[k]).substring(0, 40)).join(', ');
            } catch(_) {}
            summaryLines.push('  called ' + name + (args ? ' (' + args + ')' : ''));
          }
        } else if (turn.assistant.content) {
          summaryLines.push('  reasoning: ' + String(turn.assistant.content).substring(0, 120));
        }

        for (const tr of turn.toolResults) {
          const raw = typeof tr.content === 'string' ? tr.content : JSON.stringify(tr.content);
          const preview = raw.length > TOOL_RESULT_PREVIEW
            ? raw.substring(0, TOOL_RESULT_PREVIEW) + '…'
            : raw;
          summaryLines.push('  → ' + preview);
        }
      }
      summaryLines.push(']');

      const summaryMsg = { role: 'system', content: summaryLines.join('\n') };

      // Reconstruct: pinned head + compact summary + recent verbatim tail
      const compacted = [systemMsg, userMsg, summaryMsg];
      for (const turn of toKeep) {
        compacted.push(turn.assistant);
        for (const tr of turn.toolResults) compacted.push(tr);
        for (const reminder of turn.trailing) compacted.push(reminder);
      }
      return compacted;
    }

    // ---------------------------------------------------------------------------
    // Main agent loop
    // ---------------------------------------------------------------------------

    async function main() {
      const objective = Botwire.agent.objective;
      if (!objective) {
        Botwire.agent.complete({ success: false, summary: 'No objective provided.' });
        return;
      }

      Botwire.agent.updateStatus('Loading agent configuration…');
      const config = await Botwire.agent.getConfig();

      Botwire.agent.updateStatus('Loading LLM profiles…');
      const profiles = await Botwire.config.getLLMProfiles();
      if (!profiles || profiles.length === 0) {
        Botwire.agent.complete({ success: false, summary: 'No LLM API profiles configured.' });
        return;
      }

      // Select the profile matching the agent's profileID, or first available
      const profile = profiles.find(p => p.id === config.profileID) || profiles[0];

      Botwire.agent.updateStatus('Loading available tools…');
      const availableTools = await Botwire.tools.list();

      // Build OpenAI-compatible tool definitions
      const toolDefs = availableTools.map(t => ({
        type: 'function',
        function: {
          name: t.name,
          description: t.description,
          parameters: t.parameters
        }
      }));

      // Inject reply_to_user tool
      toolDefs.push({
        type: 'function',
        function: {
          name: 'reply_to_user',
          description: 'Send a message directly to the user in the chat interface. IMPORTANT: When a subagent (via agent_task) returns a response meant for the user, you MUST relay its full content through this tool — do NOT summarize or paraphrase it. Use terminal=true when the conversation turn is complete and no further tools need to run.',
          parameters: {
            type: 'object',
            properties: {
              message: { type: 'string', description: 'The message to send to the user. Relay subagent responses verbatim.' },
              terminal: { type: 'boolean', description: 'If true, this is the final message for this turn — execution completes after sending. If false, execution continues.' }
            },
            required: ['message']
          }
        }
      });

      // Build the initial messages array.
      // messages[0] and messages[1] are pinned — compaction never removes them.
      let messages = [];

      // [0] System message: system prompt + contexts + skills (pinned)
      const systemParts = [config.systemPrompt];
      if (config.contexts && config.contexts.length > 0) {
        systemParts.push('\n---\nContext:\n' + config.contexts.join('\n'));
      }
      messages.push({ role: 'system', content: systemParts.join('\n') });

      // [1] User message: the full objective (pinned)
      messages.push({ role: 'user', content: objective });

      const maxTurns        = config.maxTurns        || 12;
      const maxToolCalls    = config.maxToolCalls    || 40;
      const maxInputTokens  = config.maxInputTokens  || 500000;
      const maxOutputTokens = config.maxOutputTokens || 100000;
      let totalToolCalls    = 0;
      let totalInputTokens  = 0;
      let totalOutputTokens = 0;
      let lastAssistantText = '';
      let compactionCount   = 0;

      for (let turn = 0; turn < maxTurns; turn++) {

        // --- Context compaction (before each LLM request) ---
        const beforeLength = messages.length;
        messages = compactMessages(messages, maxInputTokens, totalInputTokens);
        if (messages.length < beforeLength) {
          compactionCount++;
          Botwire.agent.updateStatus(
            'Turn ' + (turn + 1) + '/' + maxTurns +
            ' — Context compacted (pass ' + compactionCount +
            ', ' + (beforeLength - messages.length) + ' messages removed)…'
          );
        } else {
          Botwire.agent.updateStatus('Turn ' + (turn + 1) + '/' + maxTurns + ' — Sending to LLM…');
        }

        let url = resolveCompletionsURL(profile.baseURL, profile.proxyPath);

        const requestBody = {
          model: profile.model,
          messages: messages,
          temperature: 0.35,
          stream: false
        };

        if (toolDefs.length > 0) {
          requestBody.tools = toolDefs;
          requestBody.tool_choice = 'auto';
        }

        let assistantContent = '';
        let toolCalls = [];

        try {
          const response = await fetch(url, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ' + profile.apiKey
            },
            body: JSON.stringify(requestBody)
          });

          const responseText = await response.text();
          if (!response.ok) {
            throw new Error(formatLLMHTTPError(response.status, responseText));
          }

          let parsed;
          try {
            parsed = JSON.parse(responseText);
          } catch(e) {
            throw new Error('Invalid JSON response from LLM. Response was: ' + responseText.substring(0, 500));
          }

          // Track token usage
          if (parsed.usage) {
            totalInputTokens  += (parsed.usage.prompt_tokens  || parsed.usage.input_tokens  || 0);
            totalOutputTokens += (parsed.usage.completion_tokens || parsed.usage.output_tokens || 0);
          }

          // Hard limits (post-compaction safety net)
          if (totalInputTokens > maxInputTokens) {
            Botwire.agent.complete({
              success: false,
              summary: 'Input token budget exceeded (' + totalInputTokens + '/' + maxInputTokens +
                       '). Compaction passes: ' + compactionCount + '. Output tokens: ' + totalOutputTokens + '.',
              actions: [], findings: [], evidence: []
            });
            return;
          }
          if (totalOutputTokens > maxOutputTokens) {
            Botwire.agent.complete({
              success: false,
              summary: 'Output token budget exceeded (' + totalOutputTokens + '/' + maxOutputTokens +
                       '). Input tokens: ' + totalInputTokens + '.',
              actions: [], findings: [], evidence: []
            });
            return;
          }

          const choice = parsed.choices && parsed.choices[0];
          if (choice && choice.message) {
            assistantContent = choice.message.content || '';
            if (choice.message.tool_calls) {
              toolCalls = choice.message.tool_calls.map(tc => ({
                id: tc.id || '',
                name: tc.function ? tc.function.name : '',
                arguments: tc.function ? tc.function.arguments : ''
              }));
            }
          }
        } catch (streamError) {
          Botwire.agent.complete({
            success: false,
            summary: 'LLM request error: ' + String(streamError.message || streamError)
          });
          return;
        }

        // Build the assistant message for history
        const assistantMsg = { role: 'assistant', content: assistantContent || null };
        if (toolCalls.length > 0) {
          assistantMsg.tool_calls = toolCalls.map(tc => ({
            id: tc.id,
            type: 'function',
            function: { name: tc.name, arguments: tc.arguments }
          }));
        }
        messages.push(assistantMsg);

        // If no tool calls, we're done — send a clean response
        if (toolCalls.length === 0) {
          let cleanContent = assistantContent || '';
          const trimmed = cleanContent.trim();
          if (trimmed.startsWith('{') || trimmed.startsWith('[') || trimmed.startsWith('```')) {
            cleanContent = '';
          }
          if (cleanContent) {
            Botwire.agent.sendMessage(cleanContent);
          }
          Botwire.agent.complete({
            success: true,
            summary: cleanContent || lastAssistantText || 'Agent completed.',
            actions: [], findings: [], evidence: []
          });
          return;
        }

        // Execute each tool call
        for (const tc of toolCalls) {
          totalToolCalls++;
          if (totalToolCalls > maxToolCalls) {
            Botwire.agent.complete({
              success: false,
              summary: 'Max tool calls reached (' + maxToolCalls +
                       '). Compaction passes: ' + compactionCount +
                       '. Tokens: in=' + totalInputTokens + ' out=' + totalOutputTokens + '.'
            });
            return;
          }

          const toolName = tc.name;
          Botwire.agent.updateStatus('Turn ' + (turn + 1) + ' — Running tool: ' + toolName);

          const toolDef    = availableTools.find(t => t.name === toolName);
          const isTerminal = toolDef && (toolDef.isTerminal === true || toolDef.isTerminal === 'true');

          let toolResult;
          try {
            let parsedArgs = {};
            try { parsedArgs = JSON.parse(tc.arguments || '{}'); } catch(_) {}

            if (toolName === 'reply_to_user') {
              const message = parsedArgs.message || '';
              const isTerminalReply = parsedArgs.terminal === true;
              if (isTerminalReply) {
                Botwire.agent.sendMessage(message);
                Botwire.agent.complete({ success: true, summary: message });
                return;
              } else {
                Botwire.agent.sendMessage(message);
                toolResult = { success: true, status: 'Message sent to user. Execution continuing.' };
                messages.push({
                  role: 'tool',
                  tool_call_id: tc.id,
                  content: JSON.stringify(toolResult)
                });
                continue;
              }
            }

            if (isTerminal) {
              Botwire.agent.complete(parsedArgs);
              return;
            }

            toolResult = await Botwire.tools.run(toolName, tc.arguments || '{}');
          } catch (toolError) {
            toolResult = {
              success: false,
              error: String(toolError.message || toolError)
            };
          }

          messages.push({
            role: 'tool',
            tool_call_id: tc.id,
            content: typeof toolResult === 'string' ? toolResult : JSON.stringify(toolResult)
          });
        }

        // Task reminder every 3 turns (also tells the LLM about compaction)
        if ((turn + 1) % 3 === 0) {
          messages.push({
            role: 'system',
            content: 'Reminder: Your current objective is: ' + objective +
                     '. Tool calls so far: ' + totalToolCalls + '/' + maxToolCalls +
                     '. Tokens: in=' + totalInputTokens + '/' + maxInputTokens +
                     ' out=' + totalOutputTokens + '/' + maxOutputTokens +
                     '. Compaction passes: ' + compactionCount +
                     '. If the objective is complete, call botengine_complete.'
          });
        }
      }

      // Hit max turns
      Botwire.agent.complete({
        success: false,
        summary: 'Reached maximum turns (' + maxTurns + ') without completion. ' +
                 'Tool calls: ' + totalToolCalls + '. Compaction passes: ' + compactionCount + '. ' +
                 'Tokens: in=' + totalInputTokens + ' out=' + totalOutputTokens + '.',
        actions: [], findings: [], evidence: []
      });
    }

    return await main().catch(function(err) {
      Botwire.agent.complete({
        success: false,
        summary: 'AgentBlock error: ' + String(err.message || err)
      });
    });

    function resolveCompletionsURL(baseURL, proxyPath) {
      let url = String(baseURL || '').trim().replace(/\/+$/, '');
      let proxy = String(proxyPath || '').trim().replace(/^\/+|\/+$/g, '');
      if (url.endsWith('/chat/completions')) return url;
      if (proxy) {
        if (url.endsWith('/' + proxy + '/v1') || url.endsWith('/' + proxy) || url.endsWith('/v1')) {
          return appendCompletionsEndpoint(url);
        }
        url += '/' + proxy;
      }
      return appendCompletionsEndpoint(url);
    }

    function appendCompletionsEndpoint(url) {
      if (url.endsWith('/chat/completions')) return url;
      if (url.endsWith('/v1')) return url + '/chat/completions';
      return url + '/v1/chat/completions';
    }

    function formatLLMHTTPError(status, bodyText) {
      let message = 'HTTP ' + status;
      try {
        const parsed = JSON.parse(bodyText || '{}');
        const nested = parsed.error && (parsed.error.message || parsed.error);
        if (nested) message += ': ' + String(nested);
      } catch (_) {
        if (bodyText) message += ': ' + String(bodyText).substring(0, 300);
      }
      return message;
    }
    """#
}
