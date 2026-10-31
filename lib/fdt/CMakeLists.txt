# The flattened devicetree, read in place (D154): the loader's, to make the
# ACPI tables (lib/dtacpi) and pass the tree on in the handoff. It
# allocates nothing.
add_library(croi-fdt STATIC Fdt/Fdt.swift)
set_target_properties(croi-fdt PROPERTIES Swift_MODULE_NAME Fdt)
