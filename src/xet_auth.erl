%% Authentication behaviour (spec Appendix A.1, OpenAPI scopes): a
%% bearer token is checked against a required scope. read covers the
%% GET/HEAD surface, write the mutating one.
-module(xet_auth).

-export([verify/3]).

-type scope() :: read | write.
-type config() :: {module(), term()}.
-export_type([scope/0, config/0]).

-callback verify(binary() | undefined, scope(), term()) ->
    {ok, term()} | {error, unauthorized | forbidden}.

-spec verify(config(), binary() | undefined, scope()) ->
    {ok, term()} | {error, unauthorized | forbidden}.
verify({Mod, Opts}, Token, Scope) ->
    Mod:verify(Token, Scope, Opts).
