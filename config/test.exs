import Config

config :vigil, autostart: false

# The suite's consent password and SkillKey secret. Not secrets: they key
# nothing outside the suite. Every write the suite makes carries a SkillKey
# (`Vigil.SkillKey`) derived from the second, so neither can be left unset.
# config/runtime.exs sets neither in :test, so these stand; this file is the
# one .sobelow-conf leaves out of the scan.
config :vigil,
  auth_password: "correct-horse-battery-staple",
  skillkey_secret: "y7CI4lMs8Utr4o5rIo2N2TqzaVmvCH4X6yjvDaLpVnzq4k5LCvhFQIPj3KnhnyKq"
