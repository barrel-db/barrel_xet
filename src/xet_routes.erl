%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Router and middleware stack for the CAS server. Endpoint handlers
%% register here as their tasks land; the skeleton serves /healthz and a
%% JSON 404, with bearer auth in front of everything under /api and /v1.
-module(xet_routes).

-export([compile/1, stack/1, error_response/2]).

%% Endpoints register under /api/v1 and /v1 (the OpenAPI spells the
%% first, xet-core clients build the second).
-spec compile(map()) -> livery_router:router().
compile(Config) ->
    Deadline = maps:get(request_timeout, Config, false),
    Limiter = data_limiter(maps:get(data_ratelimit, Config, false)),
    V1 = [
        {<<"POST">>, <<"/xorbs/:ns/:hash">>, fun xet_h_xorbs:upload/1},
        {<<"HEAD">>, <<"/xorbs/:ns/:hash">>, fun xet_h_xorbs:head/1},
        {<<"POST">>, <<"/shards">>, fun xet_h_shards:upload/1},
        {<<"GET">>, <<"/reconstructions/:hash">>, fun xet_h_reconstructions:get_v1/1},
        {<<"HEAD">>, <<"/files/:hash">>, fun xet_h_reconstructions:head_file/1},
        {<<"GET">>, <<"/xorbs/:ns/:hash/data">>, fun xet_h_data:get/1, data},
        {<<"GET">>, <<"/chunks/:ns/:hash">>, fun xet_h_chunks:get/1}
    ],
    V2 = [
        {<<"GET">>, <<"/reconstructions/:hash">>, fun xet_h_reconstructions:get_v2/1}
    ],
    Prefixed =
        prefix_routes([<<"/api/v1">>, <<"/v1">>], V1, Deadline, Limiter) ++
            prefix_routes([<<"/api/v2">>, <<"/v2">>], V2, Deadline, Limiter),
    livery_router:compile(
        [
            {<<"GET">>, <<"/healthz">>, fun health/1, route_meta(<<"GET">>, Deadline)},
            {<<"GET">>, <<"/readyz">>, xet_health:readyz(Config), route_meta(<<"GET">>, Deadline)},
            %% xet-core posts shards to the bare path.
            {<<"POST">>, <<"/shards">>, fun xet_h_shards:upload/1}
        ] ++ metrics_route(Config, Deadline) ++ admin_routes(Config, Deadline) ++ Prefixed
    ).

%% Non-spec admin surface, mounted only when explicitly enabled. Every
%% route requires the admin scope (see scope_for/2).
admin_routes(#{admin := #{enabled := true}}, Deadline) ->
    [
        {<<"GET">>, <<"/admin/stats">>, fun xet_h_admin:stats/1, route_meta(<<"GET">>, Deadline)},
        {<<"DELETE">>, <<"/admin/files/:hash">>, fun xet_h_admin:delete_file/1, undefined}
    ];
admin_routes(_Config, _Deadline) ->
    [].

%% Prometheus exposition of the instrument registry. Not exempt from
%% auth: metrics leak paths and volumes, so scrapers present a read
%% token.
metrics_route(#{metrics := true}, Deadline) ->
    [{<<"GET">>, <<"/metrics">>, livery_metrics:handler(), route_meta(<<"GET">>, Deadline)}];
metrics_route(_Config, _Deadline) ->
    [].

prefix_routes(Prefixes, Routes, Deadline, Limiter) ->
    [
        {Method, <<Prefix/binary, Pattern/binary>>, Handler, entry_meta(Route, Deadline, Limiter)}
     || Prefix <- Prefixes,
        Route <- Routes,
        {Method, Pattern, Handler} <- [route_parts(Route)]
    ].

route_parts({Method, Pattern, Handler}) -> {Method, Pattern, Handler};
route_parts({Method, Pattern, Handler, data}) -> {Method, Pattern, Handler}.

entry_meta({Method, _Pattern, _Handler}, Deadline, _Limiter) ->
    route_meta(Method, Deadline);
entry_meta({_Method, _Pattern, _Handler, data}, Deadline, Limiter) ->
    data_meta(Deadline, Limiter).

%% Deadline on the read surface only. Upload handlers stream their
%% request bodies, which livery_timeout's worker cannot receive (chunks
%% land in the request process); they keep xet_http_body's per-chunk
%% inactivity bound instead. /data responses return a file descriptor
%% the listener streams after the handler returns, so the deadline
%% bounds handler time, not transfer time.
route_meta(<<"GET">>, Ms) when is_integer(Ms) -> wrap_meta(deadline_list(Ms));
route_meta(<<"HEAD">>, Ms) when is_integer(Ms) -> wrap_meta(deadline_list(Ms));
route_meta(_Method, _Deadline) -> undefined.

data_meta(Deadline, undefined) ->
    route_meta(<<"GET">>, Deadline);
data_meta(Deadline, Limiter) ->
    wrap_meta([{livery_ratelimit, Limiter} | deadline_list(Deadline)]).

deadline_list(Ms) when is_integer(Ms) -> [{livery_timeout, #{after_ms => Ms}}];
deadline_list(_Deadline) -> [].

wrap_meta([]) -> undefined;
wrap_meta(Middleware) -> #{middleware => Middleware}.

%% The bearer-exempt /data endpoint gets its own limiter, one bucket
%% per signed URL: a leaked URL's egress is bounded without throttling
%% anything else. Sig-less requests pass the limiter and are rejected
%% by the handler (403) before any disk read. The fixed name keeps one
%% shared bucket table across router rebuilds.
data_limiter(false) ->
    undefined;
data_limiter(Opts) when is_map(Opts) ->
    Extra = maps:without([capacity, per_second], Opts),
    Merged = maps:merge(#{name => xet_data_ratelimit, key => fun data_sig_key/1}, Extra),
    livery_ratelimit:limiter(
        maps:get(capacity, Opts),
        maps:get(per_second, Opts),
        Merged
    ).

data_sig_key(Req) ->
    case uri_string:dissect_query(livery_req:query(Req)) of
        Query when is_list(Query) ->
            case proplists:get_value("sig", Query, proplists:get_value(<<"sig">>, Query)) of
                undefined -> undefined;
                Sig -> iolist_to_binary(Sig)
            end;
        _ ->
            undefined
    end.

health(_Req) ->
    livery_resp:json(200, json:encode(#{status => <<"ok">>})).

%% Listener middleware, outermost first: request id, security headers,
%% session-id logging metadata, optional observability (metrics +
%% trace), the access log (inside the trace span so its lines carry the
%% same trace_id), optional rate limiting and concurrency caps, then
%% bearer auth.
-spec stack(map()) -> [term()].
stack(Config) ->
    [{livery_request_id, #{}}] ++
        security_headers(Config) ++
        [{xet_mw_log_meta, #{}}] ++
        observability(Config) ++
        access_log(Config) ++
        ratelimit(Config) ++
        concurrency(Config) ++
        [auth_middleware(Config)].

%% Baseline hardening headers on every response (handlers can override
%% any of them); HSTS is emitted by livery only on TLS requests.
security_headers(#{security_headers := Opts}) when is_map(Opts) ->
    [{livery_security_headers, Opts}];
security_headers(_Config) ->
    [].

%% One structured line per request (method, path, status, duration,
%% request id), carrying the session id and trace id from the metadata
%% set above.
%% notice, not livery's default info: the release log level defaults to
%% notice, and access lines should show there rather than be silently
%% filtered.
access_log(#{access_log := false}) ->
    [];
access_log(_Config) ->
    [{livery_access_log, #{level => notice}}].

%% instrument-backed OpenTelemetry metrics and tracing. Both middlewares
%% degrade gracefully if the instrument registry is not running, so this
%% is safe to enable even before an exporter is configured.
observability(#{observability := true}) ->
    [
        {livery_instrument_metrics, #{meter => <<"barrel_xet">>}},
        {livery_instrument_trace, #{tracer => <<"barrel_xet">>}}
    ];
observability(_Config) ->
    [].

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
                Scope = scope_for(livery_req:method(Req), livery_req:path(Req)),
                case xet_auth:verify(AuthCfg, bearer_token(Req), Scope) of
                    {ok, _Principal} -> Next(Req);
                    {error, unauthorized} -> error_response(401, <<"unauthorized">>);
                    {error, forbidden} -> error_response(403, <<"forbidden">>)
                end
        end
    end.

requires_auth(<<"/healthz">>) ->
    false;
requires_auth(<<"/readyz">>) ->
    false;
requires_auth(Path) ->
    %% The data endpoint authenticates by URL signature (spec 13.7.1);
    %% intermediaries and browsers fetch it without bearer tokens.
    binary:longest_common_suffix([Path, <<"/data">>]) =/= 5.

%% Admin endpoints need the admin scope regardless of method; otherwise
%% GET/HEAD are reads and the mutating verbs writes (OpenAPI scopes).
scope_for(_Method, <<"/admin/", _/binary>>) -> admin;
scope_for(<<"GET">>, _Path) -> read;
scope_for(<<"HEAD">>, _Path) -> read;
scope_for(_Method, _Path) -> write.

bearer_token(Req) ->
    case livery_req:header(<<"authorization">>, Req) of
        <<"Bearer ", Token/binary>> -> Token;
        _ -> undefined
    end.

-spec error_response(100..599, binary()) -> term().
error_response(Status, Message) ->
    livery_resp:json(Status, json:encode(#{error => Message})).
