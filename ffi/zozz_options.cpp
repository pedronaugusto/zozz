//===----------------------------------------------------------------------===//
// zozz — ozz's command-line option parser, behind -Doptions. See
// zozz_options.h for why, and for the ref-counting rule ZozzOption follows.
//===----------------------------------------------------------------------===//

#include "zozz_internal.h"
#include "zozz_options.h"

#ifdef ZOZZ_WITH_OPTIONS

#include <algorithm>

#include "ozz/base/containers/vector.h"
#include "ozz/options/options.h"

namespace {
enum class OptionKind { kInt, kFloat, kBool, kString };
}  // namespace

struct ZozzOption {
  ozz::options::Option* impl;
  int32_t refcount;
  OptionKind kind;
};

struct ZozzOptionsParser {
  ozz::options::Parser impl;
  ozz::string cached_executable_path;
  ozz::vector<ZozzOption*> registered;
};

namespace {

/// ozz::options::Option::~Option is protected — deliberately, since ozz's own
/// macro-based options are never heap-deleted through a base pointer either.
/// Deleting through each concrete TypedOption<T> instead works: its own
/// destructor is public, and a derived destructor may always invoke its
/// base's regardless of the base's own access specifier.
void DeleteOption(ozz::options::Option* impl, OptionKind kind) {
  switch (kind) {
    case OptionKind::kInt:
      zozz::Delete(static_cast<ozz::options::IntOption*>(impl));
      return;
    case OptionKind::kFloat:
      zozz::Delete(static_cast<ozz::options::FloatOption*>(impl));
      return;
    case OptionKind::kBool:
      zozz::Delete(static_cast<ozz::options::BoolOption*>(impl));
      return;
    case OptionKind::kString:
      zozz::Delete(static_cast<ozz::options::StringOption*>(impl));
      return;
  }
}

/// Drops one reference; frees the option (and its underlying ozz::Option)
/// once nothing holds it.
void Release(ZozzOption* option) {
  if (--option->refcount == 0) {
    DeleteOption(option->impl, option->kind);
    zozz::Delete(option);
  }
}

ZozzResult MakeOption(ozz::options::Option* impl, OptionKind kind,
                      ZozzOption** out) {
  if (impl == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  ZozzOption* option = zozz::New<ZozzOption>();
  if (option == nullptr) {
    DeleteOption(impl, kind);
    return ZOZZ_RESULT_OUT_OF_MEMORY;
  }
  option->impl = impl;
  option->refcount = 1;
  option->kind = kind;
  *out = option;
  return ZOZZ_RESULT_OK;
}

}  // namespace

extern "C" {

ZozzResult zozzOptionsParserCreate(ZozzOptionsParser** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  ZozzOptionsParser* parser = zozz::New<ZozzOptionsParser>();
  if (parser == nullptr) return ZOZZ_RESULT_OUT_OF_MEMORY;
  *out = parser;
  return ZOZZ_RESULT_OK;
}

void zozzOptionsParserDestroy(ZozzOptionsParser* parser) {
  if (parser == nullptr) return;
  // Releases the parser's own reference to whatever a caller registered and
  // never unregistered, so a forgotten unregister cannot leak.
  for (ZozzOption* option : parser->registered) Release(option);
  zozz::Delete(parser);
}

ZozzResult zozzOptionsParserParseCommandLine(ZozzOptionsParser* parser,
                                             int argc, const char* const* argv,
                                             const char* version,
                                             const char* usage,
                                             ZozzOptionsParseResult* out) {
  if (parser == nullptr || argv == nullptr || out == nullptr) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  parser->impl.set_usage(usage);
  parser->impl.set_version(version);
  const ozz::options::ParseResult result = parser->impl.Parse(argc, argv);
  parser->cached_executable_path = parser->impl.executable_path();

  switch (result) {
    case ozz::options::kSuccess:
      *out = ZOZZ_OPTIONS_PARSE_RESULT_SUCCESS;
      return ZOZZ_RESULT_OK;
    case ozz::options::kExitSuccess:
      *out = ZOZZ_OPTIONS_PARSE_RESULT_EXIT_SUCCESS;
      return ZOZZ_RESULT_OK;
    case ozz::options::kExitFailure:
      *out = ZOZZ_OPTIONS_PARSE_RESULT_EXIT_FAILURE;
      return ZOZZ_RESULT_OK;
  }
  return ZOZZ_RESULT_INVALID_ARGUMENT;  // unreachable: ozz's enum is closed.
}

ZozzResult zozzOptionsParserHelp(ZozzOptionsParser* parser) {
  if (parser == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  parser->impl.Help();  // Writes directly to stdout.
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzOptionsParserRegister(ZozzOptionsParser* parser,
                                     ZozzOption* option) {
  if (parser == nullptr || option == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (!parser->impl.RegisterOption(option->impl)) {
    return ZOZZ_RESULT_INVALID_ARGUMENT;
  }
  option->refcount++;
  parser->registered.push_back(option);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzOptionsParserUnregister(ZozzOptionsParser* parser,
                                       ZozzOption* option) {
  if (parser == nullptr || option == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;

  // ozz::options::Parser::UnregisterOption's own return value does not mean
  // "succeeded" — it means "succeeded AND this was the last custom option",
  // per its own doc comment. `parser->registered` is this binding's own
  // record of what it registered, and is what answers "was this option
  // actually registered here" reliably.
  auto it = std::find(parser->registered.begin(), parser->registered.end(),
                      option);
  if (it == parser->registered.end()) return ZOZZ_RESULT_INVALID_ARGUMENT;

  parser->impl.UnregisterOption(option->impl);
  parser->registered.erase(it);
  Release(option);
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzOptionsParserSetUsage(ZozzOptionsParser* parser,
                                     const char* usage) {
  if (parser == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  parser->impl.set_usage(usage);
  return ZOZZ_RESULT_OK;
}

const char* zozzOptionsParserUsage(const ZozzOptionsParser* parser) {
  return parser == nullptr ? "" : parser->impl.usage();
}

ZozzResult zozzOptionsParserSetVersion(ZozzOptionsParser* parser,
                                       const char* version) {
  if (parser == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  parser->impl.set_version(version);
  return ZOZZ_RESULT_OK;
}

int zozzOptionsParserMaxOptions(const ZozzOptionsParser* parser) {
  return parser == nullptr ? 0 : parser->impl.max_options();
}

const char* zozzOptionsParserExecutableName(const ZozzOptionsParser* parser) {
  return parser == nullptr ? "" : parser->impl.executable_name();
}

const char* zozzOptionsParserExecutablePath(const ZozzOptionsParser* parser) {
  return parser == nullptr ? "" : parser->cached_executable_path.c_str();
}

ZozzResult zozzIntOptionCreate(const char* name, const char* help,
                               int32_t default_value, bool required,
                               ZozzOption** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (name == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return MakeOption(
      zozz::New<ozz::options::IntOption>(name, help,
                                         static_cast<int>(default_value),
                                         required),
      OptionKind::kInt, out);
}

ZozzResult zozzFloatOptionCreate(const char* name, const char* help,
                                 float default_value, bool required,
                                 ZozzOption** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (name == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return MakeOption(
      zozz::New<ozz::options::FloatOption>(name, help, default_value,
                                           required),
      OptionKind::kFloat, out);
}

ZozzResult zozzBoolOptionCreate(const char* name, const char* help,
                                bool default_value, bool required,
                                ZozzOption** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (name == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return MakeOption(
      zozz::New<ozz::options::BoolOption>(name, help, default_value,
                                          required),
      OptionKind::kBool, out);
}

ZozzResult zozzStringOptionCreate(const char* name, const char* help,
                                  const char* default_value, bool required,
                                  ZozzOption** out) {
  if (out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = nullptr;
  if (name == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  return MakeOption(
      zozz::New<ozz::options::StringOption>(name, help, default_value,
                                            required),
      OptionKind::kString, out);
}

void zozzOptionDestroy(ZozzOption* option) {
  if (option == nullptr) return;
  Release(option);
}

ZozzResult zozzIntOptionValue(const ZozzOption* option, int32_t* out) {
  if (option == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (option->kind != OptionKind::kInt) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = static_cast<const ozz::options::IntOption*>(option->impl)->value();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzFloatOptionValue(const ZozzOption* option, float* out) {
  if (option == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (option->kind != OptionKind::kFloat) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = static_cast<const ozz::options::FloatOption*>(option->impl)->value();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzBoolOptionValue(const ZozzOption* option, bool* out) {
  if (option == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (option->kind != OptionKind::kBool) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = static_cast<const ozz::options::BoolOption*>(option->impl)->value();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzStringOptionValue(const ZozzOption* option, const char** out) {
  if (option == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (option->kind != OptionKind::kString) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = static_cast<const ozz::options::StringOption*>(option->impl)->value();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzIntOptionDefault(const ZozzOption* option, int32_t* out) {
  if (option == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (option->kind != OptionKind::kInt) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = static_cast<const ozz::options::IntOption*>(option->impl)->default_value();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzFloatOptionDefault(const ZozzOption* option, float* out) {
  if (option == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (option->kind != OptionKind::kFloat) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = static_cast<const ozz::options::FloatOption*>(option->impl)->default_value();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzBoolOptionDefault(const ZozzOption* option, bool* out) {
  if (option == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (option->kind != OptionKind::kBool) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = static_cast<const ozz::options::BoolOption*>(option->impl)->default_value();
  return ZOZZ_RESULT_OK;
}

ZozzResult zozzStringOptionDefault(const ZozzOption* option, const char** out) {
  if (option == nullptr || out == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  if (option->kind != OptionKind::kString) return ZOZZ_RESULT_INVALID_ARGUMENT;
  *out = static_cast<const ozz::options::StringOption*>(option->impl)->default_value();
  return ZOZZ_RESULT_OK;
}

const char* zozzOptionName(const ZozzOption* option) {
  return option == nullptr ? "" : option->impl->name();
}

const char* zozzOptionHelp(const ZozzOption* option) {
  return option == nullptr ? "" : option->impl->help();
}

bool zozzOptionRequired(const ZozzOption* option) {
  return option != nullptr && option->impl->required();
}

bool zozzOptionStatisfied(const ZozzOption* option) {
  return option != nullptr && option->impl->statisfied();
}

ZozzResult zozzOptionRestoreDefault(ZozzOption* option) {
  if (option == nullptr) return ZOZZ_RESULT_INVALID_ARGUMENT;
  option->impl->RestoreDefault();
  return ZOZZ_RESULT_OK;
}

}  // extern "C"

#else  // !ZOZZ_WITH_OPTIONS

extern "C" {

ZozzResult zozzOptionsParserCreate(ZozzOptionsParser**) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
void zozzOptionsParserDestroy(ZozzOptionsParser*) {}
ZozzResult zozzOptionsParserParseCommandLine(ZozzOptionsParser*, int,
                                             const char* const*, const char*,
                                             const char*,
                                             ZozzOptionsParseResult*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzOptionsParserHelp(ZozzOptionsParser*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzOptionsParserRegister(ZozzOptionsParser*, ZozzOption*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzOptionsParserUnregister(ZozzOptionsParser*, ZozzOption*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzOptionsParserSetUsage(ZozzOptionsParser*, const char*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
const char* zozzOptionsParserUsage(const ZozzOptionsParser*) { return ""; }
ZozzResult zozzOptionsParserSetVersion(ZozzOptionsParser*, const char*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
int zozzOptionsParserMaxOptions(const ZozzOptionsParser*) { return 0; }
const char* zozzOptionsParserExecutableName(const ZozzOptionsParser*) {
  return "";
}
const char* zozzOptionsParserExecutablePath(const ZozzOptionsParser*) {
  return "";
}
ZozzResult zozzIntOptionCreate(const char*, const char*, int32_t, bool,
                               ZozzOption** out) {
  if (out != nullptr) *out = nullptr;
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzFloatOptionCreate(const char*, const char*, float, bool,
                                 ZozzOption** out) {
  if (out != nullptr) *out = nullptr;
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzBoolOptionCreate(const char*, const char*, bool, bool,
                                ZozzOption** out) {
  if (out != nullptr) *out = nullptr;
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzStringOptionCreate(const char*, const char*, const char*, bool,
                                  ZozzOption** out) {
  if (out != nullptr) *out = nullptr;
  return ZOZZ_RESULT_UNSUPPORTED;
}
void zozzOptionDestroy(ZozzOption*) {}
ZozzResult zozzIntOptionValue(const ZozzOption*, int32_t*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzFloatOptionValue(const ZozzOption*, float*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzBoolOptionValue(const ZozzOption*, bool*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
ZozzResult zozzStringOptionValue(const ZozzOption*, const char**) {
  return ZOZZ_RESULT_UNSUPPORTED;
}
const char* zozzOptionName(const ZozzOption*) { return ""; }
const char* zozzOptionHelp(const ZozzOption*) { return ""; }
bool zozzOptionRequired(const ZozzOption*) { return false; }
bool zozzOptionStatisfied(const ZozzOption*) { return false; }
ZozzResult zozzOptionRestoreDefault(ZozzOption*) {
  return ZOZZ_RESULT_UNSUPPORTED;
}

}  // extern "C"

#endif  // ZOZZ_WITH_OPTIONS
