-module(ewe_ffi).

-export([decode_packet/3]).

decode_packet(Type, Packet, Options) ->
  case erlang:decode_packet(Type, Packet, Options) of
    {ok, HttpPacket, Rest} ->
      {ok, {packet, HttpPacket, Rest}};

    {more, undefined} ->
      {ok, {more, none}};
    {more, Length} ->
      {ok, {more, {some, Length}}};

    {error, Reason} ->
      {error, Reason}
  end.