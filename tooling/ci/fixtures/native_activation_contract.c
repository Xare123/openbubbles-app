/* Synthetic static-analysis fixture. Compile/import only, never execute. */
#include <CoreFoundation/CoreFoundation.h>

static const char *activation_xml_name = "ActivationInfoXML";

__attribute__((noinline))
static long fixture_reference_only(void) {
    /* Exercise a real Mach-O CFString reference plus a plain global pointer. */
    CFStringRef field = CFSTR("FairPlaySignature");
    return CFStringGetLength(field) + activation_xml_name[0];
}

int main(void) {
    return (int)fixture_reference_only();
}
