# Names upstream marks internal, with the marker's FILE:LINE.
#
# Two markers, both ozz's own:
#   namespace  anything inside `namespace internal` — the header comment at
#              options.h:93 calls it "the internal namespace that encloses
#              private implementation details".
#   decl       a "// Internal ..." comment immediately above a declaration.
#   type       a declaration whose type names something in `namespace internal`
#              — public in name only, since a caller cannot spell the type.

FNR == 1 { depth = 0; nsdepth = -1; pending = 0; incomment = 0 }

/^[[:space:]]*namespace[[:space:]]+internal[[:space:]]*\{/ {
  if (nsdepth < 0) { nsdepth = depth; nsmark = FILENAME ":" FNR }
  depth++
  next
}
/^[[:space:]]*\/\/[[:space:]]*Internal[[:space:]]/ { pending = 1; pendmark = FILENAME ":" FNR; next }
/^[[:space:]]*\/\// { next }

{
  line = $0
  if (incomment) { p = index(line, "*/"); if (p == 0) next; line = substr(line, p+2); incomment = 0 }
  while ((a = index(line, "/*")) > 0) {
    rest = substr(line, a+2); b = index(rest, "*/")
    if (b == 0) { line = substr(line, 1, a-1); incomment = 1; break }
    line = substr(line, 1, a-1) substr(rest, b+2)
  }
  sub(/\/\/.*/, "", line)
  $0 = line
}

{
  no = gsub(/{/, "{"); nc = gsub(/}/, "}")
  depth += no - nc
  if (nsdepth >= 0 && depth <= nsdepth) nsdepth = -1
}
!NF { next }

match($0, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/) {
  pre = (RSTART > 1) ? substr($0, RSTART-1, 1) : ""
  if (pre == "." || pre == ">" || pre == ":") { pending = 0; next }
  n = substr($0, RSTART, RLENGTH-1); gsub(/[[:space:]()]/, "", n)
  if (n ~ /^(if|for|while|switch|return|sizeof|alignof|static_assert|do|else|catch|new|delete|defined|operator)/) { pending = 0; next }
  if (nsdepth >= 0)          print n "\t" nsmark "\tnamespace"
  else if ($0 ~ /internal::/) print n "\t" FILENAME ":" FNR "\ttype"
  else if (pending)          print n "\t" pendmark "\tdecl"
  pending = 0
}
