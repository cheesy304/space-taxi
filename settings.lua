data:extend({
  {
    type = "bool-setting",
    name = "space-taxi-default-passengers",
    setting_type = "runtime-global",
    default_value = true,
    order = "a",
  },
  {
    type = "int-setting",
    name = "space-taxi-hold-seconds",
    setting_type = "runtime-global",
    default_value = 120,
    minimum_value = 10,
    maximum_value = 900,
    order = "b",
  },
})
