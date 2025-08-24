-module(ewe_ffi).

-export([decode_packet/3]).

decode_packet(Type, Packet, Options) ->
  case erlang:decode_packet(Type, Packet, Options) of
    {ok, {http_request, Method, Uri, Version}, Rest} ->
      {ok, {packet, {http_request, atom_to_binary(Method), Uri, Version}, Rest}};

    {ok, {http_header, _, _, Field, Value}, Rest} ->
      {ok, {packet, {http_header, Field, Value}, Rest}};

    {ok, Bin, Rest} ->
      {ok, {packet, Bin, Rest}};

    {more, undefined} ->
      {ok, {more, none}};
    {more, Length} ->
      {ok, {more, {some, Length}}};

    {error, Reason} ->
      {error, Reason}
  end.

% TODO: Implement exception catching