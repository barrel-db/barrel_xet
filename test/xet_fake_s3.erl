%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Minimal in-memory S3 lookalike served by livery, for offline testing
%% of xet_store_s3 through real HTTP: PUT/GET(range)/HEAD/DELETE on
%% path-style /bucket/key URLs. Signatures are accepted unverified.
-module(xet_fake_s3).

-export([start/0, stop/1, fail_next/3]).

%% The h1 listener links to its starter, so a long-lived holder process
%% owns it (and the ets table) across CT callback processes.
start() ->
    Caller = self(),
    Ref = make_ref(),
    Pid = spawn(fun() -> holder(Caller, Ref) end),
    receive
        {Ref, Port, Table} -> {ok, #{port => Port, pid => Pid, table => Table}}
    after 5000 ->
        exit(Pid, kill),
        {error, fake_s3_start_timeout}
    end.

%% Make the next N PUT requests answer with Status (for exercising the
%% client's retry layer). N =:= 0 clears any pending failures.
fail_next(#{table := Table}, N, Status) ->
    true = ets:insert(Table, {fail_next, N, Status}),
    ok.

holder(Caller, Ref) ->
    Table = ets:new(xet_fake_s3, [public, set]),
    {ok, Listener} = livery:start_listener(livery_h1, #{
        port => 0,
        stack => [],
        handler => fun(Req) -> handle_req(Table, Req) end
    }),
    Caller ! {Ref, h1:server_port(Listener), Table},
    receive
        stop -> livery:stop_listener({livery_h1, Listener})
    end.

stop(#{pid := Pid}) ->
    MRef = monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    after 5000 ->
        exit(Pid, kill),
        ok
    end.

handle_req(Table, Req) ->
    Method = livery_req:method(Req),
    Path = livery_req:path(Req),
    Key = binary:part(Path, 1, byte_size(Path) - 1),
    dispatch(Method, Key, Table, Req).

dispatch(<<"PUT">>, Key, Table, Req) ->
    %% Drain the body either way so the connection stays clean.
    Body = read_body(Req),
    case take_failure(Table) of
        {fail, Status} ->
            livery_resp:new(Status, [], {full, <<>>});
        ok ->
            ets:insert(Table, {Key, Body}),
            livery_resp:new(200, [{<<"etag">>, <<"\"fake\"">>}], {full, <<>>})
    end;
dispatch(<<"HEAD">>, Key, Table, _Req) ->
    case ets:lookup(Table, Key) of
        [{_, Body}] ->
            livery_resp:new(
                200,
                [{<<"content-length">>, integer_to_binary(byte_size(Body))}],
                {full, <<>>}
            );
        [] ->
            livery_resp:new(404, [], {full, <<>>})
    end;
dispatch(<<"GET">>, Key, Table, Req) ->
    case ets:lookup(Table, Key) of
        [{_, Body}] -> serve(Body, livery_req:header(<<"range">>, Req));
        [] -> not_such_key()
    end;
dispatch(<<"DELETE">>, Key, Table, _Req) ->
    ets:delete(Table, Key),
    livery_resp:new(204, [], {full, <<>>});
dispatch(_, _, _, _) ->
    livery_resp:new(405, [], {full, <<>>}).

take_failure(Table) ->
    case ets:lookup(Table, fail_next) of
        [{fail_next, N, Status}] when N > 0 ->
            ets:insert(Table, {fail_next, N - 1, Status}),
            {fail, Status};
        _ ->
            ok
    end.

serve(Body, undefined) ->
    livery_resp:new(200, [], {full, Body});
serve(Body, <<"bytes=", Spec/binary>>) ->
    [FromBin, ToBin] = binary:split(Spec, <<"-">>),
    From = binary_to_integer(FromBin),
    To = binary_to_integer(ToBin),
    case From =< To andalso To < byte_size(Body) of
        true ->
            Slice = binary:part(Body, From, To - From + 1),
            ContentRange = io_lib:format("bytes ~b-~b/~b", [From, To, byte_size(Body)]),
            livery_resp:new(
                206,
                [{<<"content-range">>, iolist_to_binary(ContentRange)}],
                {full, Slice}
            );
        false ->
            invalid_range()
    end.

not_such_key() ->
    Xml = <<"<?xml version=\"1.0\"?><Error><Code>NoSuchKey</Code><Message>gone</Message></Error>">>,
    livery_resp:new(404, [{<<"content-type">>, <<"application/xml">>}], {full, Xml}).

invalid_range() ->
    Xml =
        <<"<?xml version=\"1.0\"?><Error><Code>InvalidRange</Code><Message>bad</Message></Error>">>,
    livery_resp:new(416, [{<<"content-type">>, <<"application/xml">>}], {full, Xml}).

read_body(Req) ->
    case livery_req:body(Req) of
        empty ->
            <<>>;
        {buffered, IoData} ->
            iolist_to_binary(IoData);
        {stream, Reader} ->
            {ok, Bin, _} = livery_body:read_all(Reader),
            Bin
    end.
