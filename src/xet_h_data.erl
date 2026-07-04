%% FS-backed data endpoint: GET /v1/xorbs/{ns}/{hash}/data?exp=..&sig=..
%%
%% Authentication is the URL signature (spec 13.7.1 query-signed
%% strategy); bearer auth is bypassed for this path. Bad or expired
%% signatures return 403, the exact status that makes clients re-query
%% reconstruction. Content headers follow 13.6.1: public + immutable
%% with max-age bounded by the signature's remaining validity, an
%% aligned Expires, and the xorb hash as ETag.
-module(xet_h_data).

-export([get/1]).

get(Req) ->
    Env = xet_server:env(livery_req:config(server, Req)),
    maybe
        {ok, Ns, HashStr, Hash} ?= target(Req, Env),
        {ok, Expiry} ?= check_signature(Req, Env, Ns, HashStr),
        {ok, Path, Size} ?= locate(Env, Ns, Hash),
        {ok, Status, Range} ?= resolve_range(Req, Size),
        respond(Status, Path, Range, HashStr, Expiry)
    else
        {error, Resp} -> Resp
    end.

target(Req, #{config := Config}) ->
    Ns = livery_req:binding(<<"ns">>, Req),
    HashStr = livery_req:binding(<<"hash">>, Req),
    Allowed = lists:member(Ns, maps:get(namespaces, Config)),
    case {Allowed, xet_hash:is_hash_string(HashStr)} of
        {true, true} -> {ok, Ns, HashStr, xet_hash:from_string(HashStr)};
        _ -> {error, xet_routes:error_response(400, <<"bad_target">>)}
    end.

check_signature(Req, #{config := Config}, Ns, HashStr) ->
    Query = uri_string:dissect_query(livery_req:query(Req)),
    Exp = proplists:get_value("exp", Query, proplists:get_value(<<"exp">>, Query)),
    Sig = proplists:get_value("sig", Query, proplists:get_value(<<"sig">>, Query)),
    maybe
        {ok, Expiry} ?= parse_expiry(Exp),
        ok ?=
            verdict(
                xet_url_signer:verify(
                    maps:get(url_secret, Config),
                    Ns,
                    HashStr,
                    Expiry,
                    to_binary(Sig),
                    erlang:system_time(second)
                )
            ),
        {ok, Expiry}
    end.

parse_expiry(undefined) ->
    {error, xet_routes:error_response(403, <<"missing_signature">>)};
parse_expiry(Value) ->
    try
        {ok, binary_to_integer(to_binary(Value))}
    catch
        error:badarg -> {error, xet_routes:error_response(403, <<"bad_signature">>)}
    end.

verdict(ok) -> ok;
verdict({error, expired}) -> {error, xet_routes:error_response(403, <<"expired">>)};
verdict({error, bad_signature}) -> {error, xet_routes:error_response(403, <<"bad_signature">>)}.

to_binary(undefined) -> <<>>;
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V).

locate(#{blob := Blob}, Ns, Hash) ->
    case xet_blob_store:local_path(Blob, Ns, Hash) of
        {ok, Path} ->
            case filelib:is_regular(Path) of
                true -> {ok, Path, filelib:file_size(Path)};
                false -> {error, xet_routes:error_response(404, <<"not_found">>)}
            end;
        {error, not_supported} ->
            %% S3 deployments hand out presigned URLs, not this endpoint.
            {error, xet_routes:error_response(404, <<"not_served_here">>)}
    end.

%% livery's file body takes {Offset, Length | eof}.
resolve_range(Req, Size) ->
    case xet_http_range:parse(livery_req:header(<<"range">>, Req)) of
        all ->
            {ok, 200, undefined};
        {range, Start, End} when Start < Size ->
            {ok, 206, {Start, min(End, Size - 1) - Start + 1}};
        {open, Start} when Start < Size ->
            {ok, 206, {Start, eof}};
        {suffix, N} when N > 0, Size > 0 ->
            {ok, 206, {max(0, Size - N), eof}};
        _ ->
            {error, xet_routes:error_response(416, <<"unsatisfiable">>)}
    end.

respond(Status, Path, Range, HashStr, Expiry) ->
    Now = erlang:system_time(second),
    MaxAge = max(Expiry - Now, 0),
    Resp = livery_resp:file(Status, Path, Range),
    lists:foldl(
        fun({Name, Value}, R) -> livery_resp:with_header(Name, Value, R) end,
        Resp,
        [
            {<<"etag">>, <<"\"", HashStr/binary, "\"">>},
            {<<"cache-control">>,
                <<"public, immutable, max-age=", (integer_to_binary(MaxAge))/binary>>},
            {<<"expires">>, http_date(Expiry)},
            {<<"accept-ranges">>, <<"bytes">>}
        ]
    ).

%% RFC 7231 IMF-fixdate.
http_date(UnixSeconds) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(UnixSeconds, second),
    Day = calendar:day_of_the_week({Y, Mo, D}),
    iolist_to_binary(
        io_lib:format(
            "~s, ~2..0b ~s ~4..0b ~2..0b:~2..0b:~2..0b GMT",
            [day_name(Day), D, month_name(Mo), Y, H, Mi, S]
        )
    ).

day_name(N) ->
    element(N, {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}).

month_name(N) ->
    element(
        N, {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
    ).
