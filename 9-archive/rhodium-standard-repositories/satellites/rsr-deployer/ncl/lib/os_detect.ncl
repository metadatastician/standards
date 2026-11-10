# ncl/lib/os_detect.ncl
# The "Omniscience" Module for the Rhodium Standard
{
  # Core detection logic via environment and shell introspection
  env = {
    os | String | default = "linux",
    arch | String | default = "x86_64",
    is_immutable | String | default = "false",
  },

  # Logic to determine the target type
  target_type =
    if env.os == "minix" then
      'Edge_ASIC
    else if env.is_immutable == "true" then
      'Kinoite_Layered
    else if env.os == "darwin" then
      'Apple_Darwin
    else
      'Standard_PC,

  # Permutation rules for the Mustfile
  deployment_priority =
    match {
      'Edge_ASIC => "static_bin",
      'Kinoite_Layered => "podman_ostree",
      'Apple_Darwin => "container_first", # explicit arm: same strategy the
      # wildcard gave it, recorded rather than inherited (#1001). Whether
      # macOS deserves "static_bin" is a design decision; when it is made,
      # it is made here, in all three byte-identical copies.
      'Standard_PC => "nala_native",
      _ => "container_first",
    } target_type,
}
