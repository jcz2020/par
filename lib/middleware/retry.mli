type retry_config = {
  max_attempts : int;
  base_delay : float;
  max_delay : float;
}

val default_retry_config : retry_config

val retry :
  ?config:retry_config ->
  ?policy:Types.retry_policy ->
  unit ->
  Types.middleware_hook
