data:extend({
  {
    type = "custom-input",
    name = "space-taxi-toggle",
    key_sequence = "CONTROL + SHIFT + T",
    action = "lua",
  },
  {
    type = "shortcut",
    name = "space-taxi",
    order = "z[space-taxi]",
    action = "lua",
    associated_control_input = "space-taxi-toggle",
    icon = "__base__/graphics/icons/cargo-pod.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/cargo-pod.png",
    small_icon_size = 64,
  },
})
