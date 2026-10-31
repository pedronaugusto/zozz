//===----------------------------------------------------------------------===//
// zozz — ozz's output streams, guarded in the test binary.
//
// ozz writes its log and its options parser's text to std::cerr, std::clog
// and std::cout. A test that expects a refusal silences ozz's log and
// asserts through the refusal record, which carries what the log would have
// said; a test that drives the options parser says it expects that text. Any
// other write is a test that printed where none should, and stops the
// process naming the stream and the text, so a passing run prints nothing.
//
// Test-only. Not part of the zozz library or its ABI.
//===----------------------------------------------------------------------===//

#ifndef ZOZZ_TEST_QUIET_H_
#define ZOZZ_TEST_QUIET_H_

#ifdef __cplusplus
extern "C" {
#endif

/// Nonzero: the next writes ozz makes are expected and dropped, until a call
/// with zero. Calls nest.
void zozzTestExpectOutput(int expect);

/// 1: the guard is installed on all three streams.
int zozzTestOutputGuarded(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ZOZZ_TEST_QUIET_H_
