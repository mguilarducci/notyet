import envoy
import notyet

pub fn read_port_defaults_when_unset_test() {
  envoy.unset("PORT")
  assert notyet.read_port() == 8000
}

pub fn read_port_parses_valid_test() {
  envoy.set("PORT", "9090")
  let port = notyet.read_port()
  envoy.unset("PORT")
  assert port == 9090
}

pub fn read_port_defaults_when_unparseable_test() {
  envoy.set("PORT", "not-a-number")
  let port = notyet.read_port()
  envoy.unset("PORT")
  assert port == 8000
}

pub fn read_secret_key_base_uses_env_when_set_test() {
  envoy.set("SECRET_KEY_BASE", "super-secret")
  let secret = notyet.read_secret_key_base()
  envoy.unset("SECRET_KEY_BASE")
  assert secret == "super-secret"
}

pub fn read_secret_key_base_falls_back_when_unset_test() {
  envoy.unset("SECRET_KEY_BASE")
  assert notyet.read_secret_key_base() == "dev_secret_key_base_change_me"
}
