# Fails if a kernel Swift source uses an atomic's checked add or subtract
# (run as cmake -P with -DSOURCES=<;-list> -DSTAMP=<file>). Swift checks
# them for overflow, so they compile to a compare-and-swap loop, LR/SC on
# RISC-V; on the Orange Pi RV2's X60 such a loop starves while another
# hart works the same cache line (an IPI's acknowledgement held its CPU,
# masked, for seconds). wrappingAdd and wrappingSubtract are one AMO.
foreach(_source ${SOURCES})
  if(_source MATCHES "\\.swift$")
    file(READ ${_source} _text)
    if(_text MATCHES "\\.(add|subtract)\\([^)]*ordering:")
      message(FATAL_ERROR "${_source}: an atomic's add or subtract is an LR/SC loop: use wrappingAdd or wrappingSubtract")
    endif()
  endif()
endforeach()
file(TOUCH ${STAMP})
