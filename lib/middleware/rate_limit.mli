type rate_limit_config = {
  max_requests : int;
  window : float;
}

val default_rate_limit_config : rate_limit_config

val rate_limit :
  ?config:rate_limit_config ->
  unit ->
  Types.middleware_hook
