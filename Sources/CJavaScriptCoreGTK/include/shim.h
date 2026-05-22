#include <jsc/jsc.h>
#include <glib.h>

// Helper to evaluate and return a promise, or undefined
static inline JSCValue* botwire_jsc_evaluate_async(JSCContext *context, const char *script) {
    return jsc_context_evaluate(context, script, -1);
}
