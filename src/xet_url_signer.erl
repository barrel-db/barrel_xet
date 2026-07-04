%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Query signing for the FS data endpoint (spec 13.7.1, query-signed
%% URLs): sig = HMAC-SHA256(secret, ns \n hash \n exp), base64url. A bad
%% or expired signature maps to 403, the status that makes clients
%% re-query reconstruction.
-module(xet_url_signer).

-export([sign/4, verify/6]).

-spec sign(binary(), binary(), xet_hash:hash_string(), non_neg_integer()) -> binary().
sign(Secret, Ns, HashStr, Expiry) ->
    Mac = crypto:mac(hmac, sha256, Secret, payload(Ns, HashStr, Expiry)),
    base64:encode(Mac, #{mode => urlsafe, padding => false}).

-spec verify(
    binary(),
    binary(),
    xet_hash:hash_string(),
    non_neg_integer(),
    binary(),
    non_neg_integer()
) -> ok | {error, expired | bad_signature}.
verify(_Secret, _Ns, _HashStr, Expiry, _Sig, Now) when Now >= Expiry ->
    {error, expired};
verify(Secret, Ns, HashStr, Expiry, Sig, _Now) ->
    Expected = sign(Secret, Ns, HashStr, Expiry),
    case
        byte_size(Expected) =:= byte_size(Sig) andalso
            crypto:hash_equals(crypto:hash(sha256, Expected), crypto:hash(sha256, Sig))
    of
        true -> ok;
        false -> {error, bad_signature}
    end.

payload(Ns, HashStr, Expiry) ->
    [Ns, $\n, HashStr, $\n, integer_to_binary(Expiry)].
