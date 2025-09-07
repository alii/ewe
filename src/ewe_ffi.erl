-module(ewe_ffi).

-export([decode_packet/3, rescue/1, validate_field_value/1, init_clock_storage/0,
         set_http_date/1, lookup_http_date/0, now/0, now_microseconds/0]).

decode_packet(Type, Packet, Options) ->
  case erlang:decode_packet(Type, Packet, Options) of
    {ok, {http_request, Method, Uri, Version}, Rest} ->
      {ok, {packet, {http_request, atom_to_binary(Method), Uri, Version}, Rest}};
    {ok, {http_header, Idx, _, Field, Value}, Rest} ->
      {ok, {packet, {http_header, Idx, Field, Value}, Rest}};
    {ok, Bin, Rest} ->
      {ok, {packet, Bin, Rest}};
    {more, undefined} ->
      {ok, {more, none}};
    {more, Length} ->
      {ok, {more, {some, Length}}};
    {error, Reason} ->
      {error, Reason}
  end.

rescue(Callable) ->
  try
    {ok, Callable()}
  catch
    error:Error ->
      {error, {errored, Error}};
    Error ->
      {error, {thrown, Error}};
    exit:Error ->
      {error, {exited, Error}}
  end.

validate_field_value(Value) ->
  case do_validate_field_value(Value) of
    true ->
      {ok, Value};
    false ->
      {error, nil}
  end.

% HTTP field values can contain:
% - VCHAR: 0x21-0x7E (visible ASCII characters)
% - WSP: 0x20 (space), 0x09 (tab)
% - obs-text: 0x80-0xFF (for backward compatibility)
% Invalid: control characters 0x00-0x08, 0x0A-0x1F, 0x7F
do_validate_field_value(Value) ->
  case Value of
    <<>> ->
      true;
    <<C, Rest/bitstring>>
      when C =:= 16#09
           orelse C >= 16#20 andalso C =< 16#7E
           orelse C >= 16#80 andalso C =< 16#FF ->
      do_validate_field_value(Rest);
    _ ->
      false
  end.

now() ->
  Timestamp = os:system_time(microsecond),
  {Date, Time} = calendar:system_time_to_universal_time(Timestamp, microsecond),
  Weekday = calendar:day_of_the_week(Date),
  {Weekday, Date, Time}.

now_microseconds() ->
  os:system_time(microsecond).

init_clock_storage() ->
  ets:new(ewe_clock, [set, protected, named_table, {read_concurrency, true}]).

set_http_date(Value) ->
  ets:insert(ewe_clock, {http_date, Value}).

lookup_http_date() ->
  try
    {ok, ets:lookup_element(ewe_clock, http_date, 2)}
  catch
    _:badarg ->
      {error, nil}
  end.
