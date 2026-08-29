//===----------------------------------------------------------------------===//
// zozz — ozz's command-line option parser (ozz/options/options.h).
//
// Behind -Doptions, off by default: options.cc writes to <iostream> in about
// twenty places and zozz otherwise never pulls that header in. Every entry
// point below is declared unconditionally and returns ZOZZ_RESULT_UNSUPPORTED
// when the library was built with -Doptions=false.
//
// ozz's own API is macro-driven (OZZ_OPTIONS_DECLARE_INT and friends declare
// options with static storage duration), which cannot cross a C ABI. This
// binds the runtime classes those macros drive instead — Option, its four
// typed subclasses, and Parser — which is equivalent in capability.
//
// A caller-owned ZozzOptionsParser, not ozz's own hidden process-global one.
// ozz::options::ParseCommandLine() and the free ParsedExecutable* functions
// only ever operate on a Parser instance private to options.cc, reached
// through the OZZ_OPTIONS_DECLARE_* macros a C host cannot use; there is no
// public accessor for it. zozzOptionsParserParseCommandLine below does what
// that free function does (set_usage, set_version, then parse), against a
// parser the caller creates and owns, which is the only Parser instance this
// ABI has any way to reach.
//
// A ZozzOption is ref-counted: creating one starts a count of 1, registering
// it with a parser adds 1, and destroying or unregistering it removes 1 —
// the object is freed only once nothing (caller or parser) still references
// it. Destroying a ZozzOptionsParser releases its own references to whatever
// is still registered. Without this, a caller destroying an option it forgot
// to unregister first would leave the parser holding a dangling pointer.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_OPTIONS_H_
#define ZOZZ_OPTIONS_H_

#include <stddef.h>
#include <stdint.h>

#ifndef __cplusplus
#include <stdbool.h>
#endif

#include "zozz_core.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZozzOptionsParser ZozzOptionsParser;
typedef struct ZozzOption ZozzOption;

ZOZZ_API ZozzResult zozzOptionsParserCreate(ZozzOptionsParser** out);

ZOZZ_API void zozzOptionsParserDestroy(ZozzOptionsParser* parser);

/// Mirrors ozz::options::ParseResult exactly, kept as its own enum rather
/// than collapsed into ZozzResult: kExitSuccess (e.g. --help was given) is
/// not a failure, and folding it into a generic error would lose that.
typedef enum ZozzOptionsParseResult {
  ZOZZ_OPTIONS_PARSE_RESULT_SUCCESS = 0,
  /// Parsed successfully, but an argument (--help, --version) requires the
  /// application to exit; not an error.
  ZOZZ_OPTIONS_PARSE_RESULT_EXIT_SUCCESS = 1,
  /// An invalid option, a missing required option, or a failed validation.
  ZOZZ_OPTIONS_PARSE_RESULT_EXIT_FAILURE = 2,
} ZozzOptionsParseResult;

/// Sets `parser`'s usage/version strings, then parses `argv[1..argc)` against
/// every option currently registered with it — argv[0] is taken as the
/// executable path, matching ozz::options::ParseCommandLine. `version` and
/// `usage` are borrowed, not copied; they must outlive `parser` or the next
/// call to this function or zozzOptionsParserSetUsage/SetVersion.
///
/// Writes the outcome to `*out`; ZOZZ_RESULT_OK means the parse machinery ran
/// without an ABI-level argument error, regardless of what `*out` says.
/// EXIT_SUCCESS and EXIT_FAILURE both write the help/usage screen to stdout
/// (see zozzOptionsParserHelp).
ZOZZ_API ZozzResult zozzOptionsParserParseCommandLine(
    ZozzOptionsParser* parser, int argc, const char* const* argv,
    const char* version, const char* usage, ZozzOptionsParseResult* out);

/// Writes the usage/help screen — every registered option, its type and its
/// default — directly to stdout, exactly as a --help argument to
/// zozzOptionsParserParseCommandLine does.
ZOZZ_API ZozzResult zozzOptionsParserHelp(ZozzOptionsParser* parser);

/// Registers `option` with `parser`. Fails (ZOZZ_RESULT_INVALID_ARGUMENT) on
/// a duplicate name, a duplicate registration of the same option, or a full
/// parser (see zozzOptionsParserMaxOptions).
ZOZZ_API ZozzResult zozzOptionsParserRegister(ZozzOptionsParser* parser,
                                              ZozzOption* option);

/// Unregisters `option` from `parser`. Fails if `option` is not currently
/// registered with `parser`.
ZOZZ_API ZozzResult zozzOptionsParserUnregister(ZozzOptionsParser* parser,
                                                ZozzOption* option);

ZOZZ_API ZozzResult zozzOptionsParserSetUsage(ZozzOptionsParser* parser,
                                              const char* usage);

/// Borrowed; valid until the next SetUsage/ParseCommandLine call or Destroy.
ZOZZ_API const char* zozzOptionsParserUsage(const ZozzOptionsParser* parser);

ZOZZ_API ZozzResult zozzOptionsParserSetVersion(ZozzOptionsParser* parser,
                                                const char* version);

/// Capacity for custom options (excludes the two built-in --help/--version).
ZOZZ_API int zozzOptionsParserMaxOptions(const ZozzOptionsParser* parser);

/// Borrowed; "" until zozzOptionsParserParseCommandLine has run once.
ZOZZ_API const char* zozzOptionsParserExecutableName(
    const ZozzOptionsParser* parser);

/// Borrowed; "" until zozzOptionsParserParseCommandLine has run once. Valid
/// until the next ParseCommandLine call or Destroy.
ZOZZ_API const char* zozzOptionsParserExecutablePath(
    const ZozzOptionsParser* parser);

//===----------------------------------------------------------------------===//
// Options
//
// One opaque type for all four value types (int, float, bool, string): the
// per-type Create functions below tag the handle with its kind, and the
// per-type Value readers reject a mismatched kind with
// ZOZZ_RESULT_INVALID_ARGUMENT rather than reading the wrong union member.
//===----------------------------------------------------------------------===//

/// `name` and `help` are borrowed, not copied (ozz::options::Option stores
/// the pointers it is given); both must outlive the returned ZozzOption.
ZOZZ_API ZozzResult zozzIntOptionCreate(const char* name, const char* help,
                                        int32_t default_value, bool required,
                                        ZozzOption** out);

ZOZZ_API ZozzResult zozzFloatOptionCreate(const char* name, const char* help,
                                          float default_value, bool required,
                                          ZozzOption** out);

ZOZZ_API ZozzResult zozzBoolOptionCreate(const char* name, const char* help,
                                         bool default_value, bool required,
                                         ZozzOption** out);

/// `default_value` is borrowed the same way (ozz's TypedOption<const char*>
/// stores the pointer, not a copy); it must outlive the returned ZozzOption.
ZOZZ_API ZozzResult zozzStringOptionCreate(const char* name, const char* help,
                                           const char* default_value,
                                           bool required, ZozzOption** out);

/// Releases the caller's reference (see the ref-counting note above); accepts
/// NULL.
ZOZZ_API void zozzOptionDestroy(ZozzOption* option);

ZOZZ_API ZozzResult zozzIntOptionValue(const ZozzOption* option, int32_t* out);
ZOZZ_API ZozzResult zozzFloatOptionValue(const ZozzOption* option, float* out);
ZOZZ_API ZozzResult zozzBoolOptionValue(const ZozzOption* option, bool* out);

/// Borrowed: the option's own default_value pointer until a command line is
/// parsed, then a pointer into whichever argv this option's value last
/// parsed from (ozz::options::Parse points into argv rather than copying) —
/// valid only as long as that buffer is.
ZOZZ_API ZozzResult zozzStringOptionValue(const ZozzOption* option,
                                          const char** out);

/// The default this option was created with, unchanged by parsing.
/// ZOZZ_RESULT_INVALID_ARGUMENT if the option is not of this type.
ZOZZ_API ZozzResult zozzIntOptionDefault(const ZozzOption* option,
                                         int32_t* out);
ZOZZ_API ZozzResult zozzFloatOptionDefault(const ZozzOption* option,
                                           float* out);
ZOZZ_API ZozzResult zozzBoolOptionDefault(const ZozzOption* option,
                                          bool* out);
/// Borrowed from the option; valid until it is destroyed.
ZOZZ_API ZozzResult zozzStringOptionDefault(const ZozzOption* option,
                                            const char** out);

/// Borrowed from whatever `name` was passed to this option's Create call.
ZOZZ_API const char* zozzOptionName(const ZozzOption* option);

/// Borrowed from whatever `help` was passed to this option's Create call.
ZOZZ_API const char* zozzOptionHelp(const ZozzOption* option);

ZOZZ_API bool zozzOptionRequired(const ZozzOption* option);

/// A required option is statisfied once it has been parsed; a non-required
/// one always is. (Spelling matches ozz::options::Option::statisfied().)
ZOZZ_API bool zozzOptionStatisfied(const ZozzOption* option);

ZOZZ_API ZozzResult zozzOptionRestoreDefault(ZozzOption* option);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_OPTIONS_H_
