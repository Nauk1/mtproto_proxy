%%% @author Sergey <me@seriyps.ru>
%%% @copyright (C) 2018, Sergey
%%% @doc
%%% This module provieds a comination of crypto and packet codecs.
%%% Crypto is always outer layer and packet is inner:
%%% ( --- packet --- )
%%%   (-- crypto --)
%%%      - tcp -
%%% @end
%%% Created :  6 Jun 2018 by Sergey <me@seriyps.ru>

-module(mtp_codec).

-export([new/4,
         decompose/1,
         try_decode_packet/2,
         encode_packet/2,
         fold_packets/4]).
-export_type([codec/0]).

-type state() :: any().
-type crypto_codec() :: mtp_aes_cbc
                      | mtp_obfuscated
                      | mtp_noop_codec.
-type packet_codec() :: mtp_abridged
                      | mtp_full
                      | mtp_intermediate
                      | mtp_secure.

-record(codec,
        {crypto_mod :: crypto_codec(),
         crypto_state :: any(),
         packet_mod :: packet_codec(),
         packet_state :: any()}).

-define(APP, mtproto_proxy).

-callback try_decode_packet(binary(), state()) ->
    {ok, binary(), state()}
        | {incomplete, state()}.

-callback encode_packet(iodata(), state()) ->
    {iodata(), state()}.

-opaque codec() :: #codec{}.


-spec new(crypto_codec(), state(), packet_codec(), state()) -> codec().
new(CryptoMod, CryptoState, PacketMod, PacketState) ->
    #codec{crypto_mod = CryptoMod,
           crypto_state = CryptoState,
           packet_mod = PacketMod,
           packet_state = PacketState}.

-spec decompose(codec()) -> {crypto_codec(), state(), packet_codec(), state()}.
decompose(#codec{crypto_mod = CryptoMod, crypto_state = CryptoState,
                 packet_mod = PacketMod, packet_state = PacketState}) ->
    {CryptoMod, CryptoState, PacketMod, PacketState}.


%% try_decode_packet(Inner) |> try_decode_packet(Outer)
-spec try_decode_packet(binary(), codec()) -> {ok, binary(), codec()} | {incomplete, codec()}.
try_decode_packet(Bin, #codec{crypto_mod = CryptoMod,
                              crypto_state = CryptoSt,
                              packet_mod = PacketMod,
                              packet_state = PacketSt} = S) ->
    {Dec1, CryptoSt1} =
        case CryptoMod:try_decode_packet(Bin, CryptoSt) of
            {incomplete, PacketSt1_} ->
                %% We have to check if something is left in packet's buffers
                {<<>>, PacketSt1_};
            {ok, Dec1_, PacketSt1_} ->
                {Dec1_, PacketSt1_}
        end,
    case PacketMod:try_decode_packet(Dec1, PacketSt) of
        {incomplete, PacketSt1} ->
            {incomplete, S#codec{crypto_state = CryptoSt1,
                                 packet_state = PacketSt1}};
        {ok, Dec2, PacketSt1} ->
            {ok, Dec2, S#codec{crypto_state = CryptoSt1,
                               packet_state = PacketSt1}}
    end.

%% encode_packet(Outer) |> encode_packet(Inner)
-spec encode_packet(iodata(), codec()) -> {iodata(), codec()}.
encode_packet(Bin, #codec{packet_mod = PacketMod,
                          packet_state = PacketSt,
                          crypto_mod = CryptoMod,
                          crypto_state = CryptoSt} = S) ->
    {Enc1, PacketSt1} = PacketMod:encode_packet(Bin, PacketSt),
    {Enc2, CryptoSt1} = CryptoMod:encode_packet(Enc1, CryptoSt),
    {Enc2, S#codec{crypto_state = CryptoSt1, packet_state = PacketSt1}}.


-spec fold_packets(fun( (binary(), FoldSt, codec()) -> FoldSt ),
                   FoldSt, binary(), codec()) ->
                          {ok, FoldSt, codec()}
                              when
      FoldSt :: any().
fold_packets(Fun, FoldSt, Data, Codec) ->
    case try_decode_packet(Data, Codec) of
        {ok, Decoded, Codec1} ->
            {FoldSt1, Codec2} = Fun(Decoded, FoldSt, Codec1),
            fold_packets(Fun, FoldSt1, <<>>, Codec2);
        {incomplete, Codec1} ->
            {ok, FoldSt, Codec1}
    end.
