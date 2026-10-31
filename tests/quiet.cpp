//===----------------------------------------------------------------------===//
// zozz — ozz's output streams, guarded in the test binary. See tests/quiet.h.
//===----------------------------------------------------------------------===//

#include "quiet.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <streambuf>

namespace {

/// How many callers expect ozz's output now.
std::atomic<int> expected{0};

/// Stands in for one stream's buffer: drops an expected write, and stops the
/// process on any other, naming the stream and what was written.
class Guard : public std::streambuf {
 public:
  Guard(const char* name, std::ostream& stream)
      : name_(name), stream_(stream), original_(stream.rdbuf(this)) {}
  ~Guard() override { stream_.rdbuf(original_); }

  bool installed() const { return stream_.rdbuf() == this; }

 protected:
  int overflow(int c) override {
    if (traits_type::eq_int_type(c, traits_type::eof())) {
      return traits_type::not_eof(c);
    }
    const char ch = traits_type::to_char_type(c);
    xsputn(&ch, 1);
    return c;
  }

  std::streamsize xsputn(const char* s, std::streamsize n) override {
    if (n == 0 || expected.load() > 0) return n;
    std::fprintf(stderr, "zozz test: ozz wrote to %s where no test expects it: %.*s\n",
                 name_, static_cast<int>(n), s);
    std::fflush(stderr);
    std::abort();
  }

 private:
  const char* name_;
  std::ostream& stream_;
  std::streambuf* original_;
};

Guard cerr_guard("std::cerr", std::cerr);
Guard clog_guard("std::clog", std::clog);
Guard cout_guard("std::cout", std::cout);

}  // namespace

extern "C" {

void zozzTestExpectOutput(int expect) { expected += expect ? 1 : -1; }

int zozzTestOutputGuarded(void) {
  return cerr_guard.installed() && clog_guard.installed() && cout_guard.installed();
}

}  // extern "C"
