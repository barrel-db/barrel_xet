%% Router and middleware stack for the CAS server. Endpoint handlers
%% register here as their tasks land; the skeleton serves /healthz and a
%% JSON 404, with bearer auth in front of everything under /api and /v1.
-module(xet_routes).

-export([compile/1, stack/1, error_response/2]).

%% Endpoints register under /api/v1 and /v1 (the OpenAPI spells the
%% first, xet-core clients build the second).
-spec compile(map()) -> livery_router:router().
compile(_Config) ->
    V1 = [
        {<<"POST">>, <<"/xorbs/:ns/:hash">>, fun xet_h_xorbs:upload/1},
        {<<"HEAD">>, <<"/xorbs/:ns/:hash">>, fun xet_h_xorbs:head/1},
        {<<"POST">>, <<"/shards">>, fun xet_h_shards:upload/1},
        {<<"GET">>, <<"/reconstructions/:hash">>, fun xet_h_reconstructions:get_v1/1},
        {<<"HEAD">>, <<"/files/:hash">>, fun xet_h_reconstructions:head_file/1},
        {<<"GET">>, <<"/xorbs/:ns/:hash/data">>, fun xet_h_data:get/1},
        {<<"GET">>, <<"/chunks/:ns/:hash">>, fun xet_h_chunks:get/1}
    ],
    V2 = [
        {<<"GET">>, <<"/reconstructions/:hash">>, fun xet_h_reconstructions:get_v2/1}
    ],
    Prefixed =
        [
            {Method, <<Prefix/binary, Pattern/binary>>, Handler}
         || Prefix <- [<<"/api/v1">>, <<"/v1">>],
            {Method, Pattern, Handler} <- V1
        ] ++
            [
                {Method, <<Prefix/binary, Pattern/binary>>, Handler}
             || Prefix <- [<<"/api/v2">>, <<"/v2">>],
                {Method, Pattern, Handler} <- V2
            ],
    livery_router:compile([
        {<<"GET">>, <<"/healthz">>, fun health/1},
        %% xet-core posts shards to the bare path.
        {<<"POST">>, <<"/shards">>, fun xet_h_shards:upload/1}
        | Prefixed
    ]).

health(_Req) ->
    livery_resp:json(200, json:encode(#{status => <<"ok">>})).

%% Listener middleware, outermost first: request id, optional rate
%% limiting and concurrency caps, then bearer auth.
-spec stack(map()) -> [term()].
stack(Config) ->
    [{livery_request_id, #{}}] ++
        ratelimit(Config) ++
        concurrency(Config) ++
        [auth_middleware(Config)].

%% Token bucket per bearer token: #{capacity := N, per_second := Rate}
%% plus any livery_ratelimit option (key fun, status, ...).
ratelimit(#{ratelimit := false}) ->
    [];
ratelimit(#{ratelimit := Opts}) ->
    Limiter = livery_ratelimit:limiter(
        maps:get(capacity, Opts),
        maps:get(per_second, Opts),
        maps:without([capacity, per_second], Opts)
    ),
    [{livery_ratelimit, Limiter}].

concurrency(#{concurrency := false}) ->
    [];
concurrency(#{concurrency := Max}) when is_integer(Max) ->
    [{livery_concurrency, livery_concurrency:limiter(Max)}].

%% Bearer auth for the API surface. GET and HEAD need the read scope,
%% everything else write (matching the OpenAPI security scopes). Health
%% stays open; the signed data endpoint (T5.5) authenticates by URL
%% signature instead and is skipped here.
auth_middleware(#{auth := AuthCfg}) ->
    fun(Req, Next) ->
        case requires_auth(livery_req:path(Req)) of
            false ->
                Next(Req);
            true ->
                Scope = scope_for(livery_req:method(Req)),
                case xet_auth:verify(AuthCfg, bearer_token(Req), Scope) of
                    {ok, _Principal} -> Next(Req);
                    {error, unauthorized} -> error_response(401, <<"unauthorized">>);
                    {error, forbidden} -> error_response(403, <<"forbidden">>)
                end
        end
    end.

requires_auth(<<"/healthz">>) ->
    false;
requires_auth(Path) ->
    %% The data endpoint authenticates by URL signature (spec 13.7.1);
    %% intermediaries and browsers fetch it without bearer tokens.
    binary:longest_common_suffix([Path, <<"/data">>]) =/= 5.

scope_for(<<"GET">>) -> read;
scope_for(<<"HEAD">>) -> read;
scope_for(_) -> write.

bearer_token(Req) ->
    case livery_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> -> Token;
        _ -> undefined
    end.

-spec error_response(100..599, binary()) -> term().
error_response(Status, Message) ->
    livery_resp:json(Status, json:encode(#{error => Message})).
