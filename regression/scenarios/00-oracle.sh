# 00-oracle — sanity: the device oracle itself works, before any SideStep operation.
# If this fails, nothing downstream can be trusted. Asserts against installd directly.

# The oracle can browse installd and sees a non-trivial app list.
_count="$(oracle apps "$UDID" | awk '/>>> APPS OK/{print $4}')"
[ -n "$_count" ] && [ "$_count" -gt 0 ] 2>/dev/null \
  && pass "oracle browses installd ($_count user apps)" \
  || fail "oracle browses installd" "no app list returned"

# A known-present sideloaded app resolves (proves appinfo + version parsing).
assert_device_installed "known app present (Stay on Track)" "$UDID" "com.sidestep.stayontrack.xls3xf57j8"

# A bundle id that cannot exist must report ABSENT (proves negative assertions work —
# this is the exact check that would have caught the false-OK install bug).
assert_device_absent "bogus bundle id reports absent" "$UDID" "com.sidestep.__does_not_exist__"
