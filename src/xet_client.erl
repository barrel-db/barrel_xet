%% XET CAS client: raw endpoint calls over livery_client. Auth (bearer +
%% optional refresh), the xet-core retry taxonomy (xet_client_retry), a
%% per-client X-Xet-Session-Id, and V2-first reconstruction with V1
%% fallback. Upload/download pipelines build on these in later tasks.
%%
%% Path dialect: draft (default) uses /api/v1 and /api/v2; hf posts
%% shards to the bare /shards path and uses /v1, /v2 (xet-core style).
-module(xet_client).

-export([new/1]).
-export([
    upload_xorb/4,
    head_xorb/3,
    upload_shard/2,
    get_reconstruction/2,
    get_reconstruction/3,
    query_chunk/3,
    head_file/2
]).

-type client() :: #{
    http := term(),
    token := xet_client_token:provider(),
    dialect := draft | hf,
    session_id := binary(),
    retry := map(),
    timeout := timeout()
}.
-export_type([client/0]).

-spec new(map()) -> client().
new(Opts) ->
    Endpoint = maps:get(endpoint, Opts),
    #{
        http => livery_client:new(#{base_url => Endpoint, stack => maps:get(stack, Opts, [])}),
        token => xet_client_token:new(maps:get(token, Opts, <<>>)),
        dialect => maps:get(dialect, Opts, draft),
        session_id => maps:get(session_id, Opts, gen_session_id()),
        retry => maps:merge(xet_client_retry:defaults(), maps:get(retry, Opts, #{})),
        timeout => maps:get(timeout, Opts, 300000)
    }.

%%--------------------------------------------------------------------
%% Raw calls
%%--------------------------------------------------------------------

-spec upload_xorb(client(), binary(), xet_hash:hash(), iodata()) ->
    {ok, #{was_inserted := boolean()}} | {error, term()}.
upload_xorb(Client, Ns, Hash, Body) ->
    Path = xorb_path(Client, Ns, Hash),
    case request(Client, post, Path, #{body => Body, content_type => octet_stream()}) of
        {ok, #{status := 200} = Resp} -> {ok, decode_bool(body_of(Resp))};
        Other -> error_of(Other)
    end.

-spec head_xorb(client(), binary(), xet_hash:hash()) -> {ok, boolean()} | {error, term()}.
head_xorb(Client, Ns, Hash) ->
    exists(Client, xorb_path(Client, Ns, Hash)).

-spec upload_shard(client(), iodata()) -> {ok, #{result := integer()}} | {error, term()}.
upload_shard(Client, Body) ->
    %% Shard uploads run without a read timeout: server-side processing
    %% time scales with the shard's entry count.
    Opts = #{body => Body, content_type => octet_stream(), timeout => infinity},
    case request(Client, post, shards_path(Client), Opts) of
        {ok, #{status := 200} = Resp} ->
            #{<<"result">> := Result} = json:decode(body_of(Resp)),
            {ok, #{result => Result}};
        Other ->
            error_of(Other)
    end.

-spec get_reconstruction(client(), xet_hash:hash()) -> {ok, map()} | {error, term()}.
get_reconstruction(Client, FileHash) ->
    get_reconstruction(Client, FileHash, all).

%% V2 first; on 404 or 501 fall back to V1. 416 (from an out-of-range
%% request) is surfaced as {error, range_not_satisfiable}, not retried.
-spec get_reconstruction(client(), xet_hash:hash(), xet_reconstruction:range()) ->
    {ok, map()} | {error, term()}.
get_reconstruction(Client, FileHash, Range) ->
    HashStr = xet_hash:to_string(FileHash),
    Headers = range_header(Range),
    case reconstruction(Client, v2, HashStr, Headers) of
        {ok, #{status := 200} = Resp} ->
            {ok, json:decode(body_of(Resp))};
        {ok, #{status := Status}} when Status =:= 404; Status =:= 501 ->
            reconstruction_v1(Client, HashStr, Headers);
        Other ->
            reconstruction_error(Other)
    end.

reconstruction_v1(Client, HashStr, Headers) ->
    case reconstruction(Client, v1, HashStr, Headers) of
        {ok, #{status := 200} = Resp} -> {ok, json:decode(body_of(Resp))};
        Other -> reconstruction_error(Other)
    end.

reconstruction_error({ok, #{status := 404}}) -> {error, not_found};
reconstruction_error({ok, #{status := 416}}) -> {error, range_not_satisfiable};
reconstruction_error(Other) -> error_of(Other).

%% Global dedup query: 404 is an expected miss, 429 is fatal (no retry).
-spec query_chunk(client(), binary(), xet_hash:hash()) ->
    {ok, xet_shard:shard()} | not_found | {error, term()}.
query_chunk(Client, Ns, ChunkHash) ->
    Path = chunk_path(Client, Ns, ChunkHash),
    Retry = maps:merge(maps:get(retry, Client), #{no_retry_statuses => [429]}),
    case request(Client#{retry := Retry}, get, Path, #{}) of
        {ok, #{status := 200} = Resp} -> xet_shard:decode(body_of(Resp));
        {ok, #{status := 404}} -> not_found;
        Other -> error_of(Other)
    end.

-spec head_file(client(), xet_hash:hash()) -> {ok, boolean()} | {error, term()}.
head_file(Client, FileHash) ->
    exists(Client, file_path(Client, FileHash)).

%%--------------------------------------------------------------------
%% Request plumbing
%%--------------------------------------------------------------------

exists(Client, Path) ->
    case request(Client, head, Path, #{}) of
        {ok, #{status := 200}} -> {ok, true};
        {ok, #{status := 404}} -> {ok, false};
        Other -> error_of(Other)
    end.

reconstruction(Client, Version, HashStr, Headers) ->
    request(Client, get, reconstruction_path(Client, Version, HashStr), #{headers => Headers}).

request(#{http := Http, retry := Retry} = Client, Method, Path, Opts) ->
    case auth_headers(Client) of
        {ok, Auth} ->
            ReqOpts = build_opts(Opts, Auth),
            xet_client_retry:run(
                fun() -> livery_client:request(Http, Method, Path, ReqOpts) end,
                Retry
            );
        {error, _} = Error ->
            Error
    end.

build_opts(Opts, Auth) ->
    Headers = Auth ++ content_type_header(Opts) ++ maps:get(headers, Opts, []),
    Base = #{headers => Headers},
    Base1 = maybe_put(body, maps:get(body, Opts, undefined), Base),
    maybe_put(timeout, maps:get(timeout, Opts, undefined), Base1).

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> maps:put(Key, Value, Map).

auth_headers(#{token := Token, session_id := Sid}) ->
    Session = [{<<"x-xet-session-id">>, Sid}],
    case xet_client_token:get(Token) of
        {ok, <<>>} -> {ok, Session};
        {ok, Bearer} -> {ok, [{<<"authorization">>, <<"Bearer ", Bearer/binary>>} | Session]};
        {error, _} = Error -> Error
    end.

content_type_header(#{content_type := CT}) -> [{<<"content-type">>, CT}];
content_type_header(_) -> [].

octet_stream() -> <<"application/octet-stream">>.

%% livery_client bodies arrive wrapped; unwrap to a binary.
body_of(#{body := {full, Bin}}) -> Bin;
body_of(#{body := Bin}) when is_binary(Bin) -> Bin;
body_of(#{body := IoData}) -> iolist_to_binary(IoData).

decode_bool(Body) ->
    #{<<"was_inserted">> := Inserted} = json:decode(Body),
    #{was_inserted => Inserted}.

error_of({ok, #{status := Status} = Resp}) -> {error, {http, Status, body_of(Resp)}};
error_of({error, Reason}) -> {error, Reason}.

range_header(all) ->
    [];
range_header({Start, End}) ->
    [
        {<<"range">>,
            iolist_to_binary(["bytes=", integer_to_binary(Start), "-", integer_to_binary(End)])}
    ].

%%--------------------------------------------------------------------
%% Paths
%%--------------------------------------------------------------------

xorb_path(Client, Ns, Hash) ->
    <<(api1(Client))/binary, "/xorbs/", Ns/binary, "/", (xet_hash:to_string(Hash))/binary>>.

chunk_path(Client, Ns, Hash) ->
    <<(api1(Client))/binary, "/chunks/", Ns/binary, "/", (xet_hash:to_string(Hash))/binary>>.

file_path(Client, Hash) ->
    <<(api1(Client))/binary, "/files/", (xet_hash:to_string(Hash))/binary>>.

reconstruction_path(Client, v1, HashStr) ->
    <<(api1(Client))/binary, "/reconstructions/", HashStr/binary>>;
reconstruction_path(Client, v2, HashStr) ->
    <<(api2(Client))/binary, "/reconstructions/", HashStr/binary>>.

shards_path(#{dialect := hf}) -> <<"/shards">>;
shards_path(Client) -> <<(api1(Client))/binary, "/shards">>.

api1(#{dialect := hf}) -> <<"/v1">>;
api1(_) -> <<"/api/v1">>.

api2(#{dialect := hf}) -> <<"/v2">>;
api2(_) -> <<"/api/v2">>.

gen_session_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).
