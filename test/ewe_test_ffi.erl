-module(ewe_test_ffi).
-export([rescue/1]).

%% Try to call F(). If it crashes (EXIT, throw, error), return {error, nil}.
%% Otherwise return {ok, Result}.
rescue(F) ->
    try
        {ok, F()}
    catch
        _:_ -> {error, nil}
    end.
