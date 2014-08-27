%% @doc
%%   This module implements a generic RADIUS server. A handler callback module
%%   is used to process requests. The handler module is selected based on the NAS that
%%   sent the request. Requests from unknown NASs are discarded.
%%
%%   It is also possible to run request handlers on remote nodes. If configured,
%%   the server process will balance load among connected nodes.
%%   Please see the Overview page for a detailed description of the server configuration.
%%
%%   == Callback Description ==
%%
%%   There is only one callback at the moment.
%%
%%   === radius_request(#radius_request{}, #nas_prop{}, HandlerData :: term()) -> {reply, #radius_request{}} | noreply ===
%%
%%   This function is called for every RADIUS request that is received by the server.
%%   Its first argument is a request record which contains the request type and AVPs.
%%   The second argument is a NAS descriptor. The third argument is an opaque term from the
%%   server configuration.
%%
%%   Both records are defined in 'eradius_lib.hrl', but their definition is reproduced here for easy reference.
%%
%%   ```
%%   -record(radius_request, {
%%       reqid         :: byte(),
%%       cmd           :: 'request' | 'accept' | 'challenge' | 'reject' | 'accreq' | 'accresp' | 'coareq' | 'coaack' | 'coanak' | 'discreq' | 'discack' | 'discnak'm
%%       attrs         :: eradius_lib:attribute_list(),
%%       secret        :: eradius_lib:secret(),
%%       authenticator :: eradius_lib:authenticator(),
%%       msg_hmac      :: boolean(),
%%       eap_msg       :: binary()
%%   }).
%%
%%   -record(nas_prop, {
%%       server_ip     :: inet:ip_address(),
%%       server_port   :: eradius_server:port_number(),
%%       nas_ip        :: inet:ip_address(),
%%       nas_port      :: eradius_server:port_number(),
%%       secret        :: eradius_lib:secret(),
%%       trace         :: boolean(),
%%       handler_nodes :: 'local' | list(atom())
%%   }).
%%   '''
-module(eradius_server).
-export([start_link/3, behaviour_info/1]).
-export_type([port_number/0, req_id/0]).

%% internal
-export([do_radius_queue/6, handle_request/3, handle_remote_request/5, stats/2]).

-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("eradius_lib.hrl").

-define(RESEND_TIMEOUT, 5000).          % how long the binary response is kept after sending it on the socket
-define(RESEND_RETRIES, 3).             % how often a reply may be resent
-define(HANDLER_REPLY_TIMEOUT, 15000).  % how long to wait before a remote handler is considered dead

-type name()        :: atom().
-type port_number() :: 1..65535.
-type req_id()      :: byte().
-type udp_socket()  :: port().
-type udp_packet()  :: {udp, udp_socket(), inet:ip_address(), port_number(), binary()}.
-type options()     :: [option()].
-type option()      :: {rate_config, list()}.

-record(state, {
    name           :: atom(),            % Generated server name
    socket         :: udp_socket(),      % Socket Reference of opened UDP port
    ip = {0,0,0,0} :: inet:ip_address(), % IP to which this socket is bound
    port = 0       :: port_number(),     % Port number we are listening on
    transacts      :: ets:tid(),         % ETS table containing current transactions
    counter        :: #server_counter{}  % statistics counter
}).

-spec behaviour_info('callbacks') -> [{module(), non_neg_integer()}].
behaviour_info(callbacks) -> [{radius_request,3}].

%% @private
-spec start_link(inet:ip4_address(), port_number(), options()) -> {ok, pid()} | {error, term()}.
start_link(IP = {A,B,C,D}, Port, Options) ->
    Name = list_to_atom(lists:flatten(io_lib:format("eradius_server_~b.~b.~b.~b:~b", [A,B,C,D,Port]))),
    gen_server:start_link({local, Name}, ?MODULE, {Name, IP, Port, Options}, []).

stats(Server, Function) ->
    gen_server:call(Server, {stats, Function}).

%% ------------------------------------------------------------------------------------------
%% -- gen_server Callbacks
%% @private
init({Name, IP, Port, Options}) ->
    process_flag(trap_exit, true),
    eradius_jobs:start(Name, proplists:get_value(rate_config, Options)),
    case gen_udp:open(Port, [{active, once}, {ip, IP}, binary]) of
        {ok, Socket} ->
            {ok, #state{name = Name,
                        socket = Socket,
                        ip = IP, port = Port,
                        transacts = ets:new(transacts, []),
                        counter = eradius_counter:init_counter({IP, Port})}};
        {error, Reason} ->
            {stop, Reason}
    end.

%% @private
handle_info(ReqUDP = {udp, Socket, FromIP, FromPortNo, Packet}, State = #state{name = Name, transacts = Transacts}) ->
    NewState = case lookup_nas(State, FromIP, Packet) of
                   {ok, ReqID, Handler, NasProp} ->
                       ReqKey = {FromIP, FromPortNo, ReqID},
                       NNasProp = NasProp#nas_prop{nas_port = FromPortNo},
                       case ets:lookup(Transacts, ReqKey) of
                           [] ->
                               HandlerPid = proc_lib:spawn_link(?MODULE, do_radius_queue, [Name, self(), ReqKey, Handler, NNasProp, ReqUDP]),
                               ets:insert(Transacts, {ReqKey, {handling, HandlerPid}}),
                               eradius_counter:inc_counter(requests, NasProp);
                           [{_ReqKey, {handling, _HandlerPid}}] ->
                               %% handler process is still working on the request
                               dbg(NasProp, "duplicate request (being handled) ~p~n", [ReqKey]),
                               eradius_counter:inc_counter(dupRequests, NasProp);
                           [{_ReqKey, {replied, HandlerPid}}] ->
                               %% handler process waiting for resend message
                               HandlerPid ! {self(), resend, Socket},
                               dbg(NasProp, "duplicate request (resend) ~p~n", [ReqKey]),
                               eradius_counter:inc_counter(dupRequests, NasProp)
                       end,
                       State;
                   {discard, Reason} when Reason == no_nodes_local, Reason == no_nodes ->
                       State#state{counter = eradius_counter:inc_counter(discardNoHandler, State#state.counter)};
                   {discard, _Reason} ->
                       State#state{counter = eradius_counter:inc_counter(invalidRequests, State#state.counter)}
               end,
    eradius_inet:setopts(Socket, [{active, once}]),
    {noreply, NewState};
handle_info({replied, ReqKey, HandlerPid}, State = #state{transacts = Transacts}) ->
    ets:insert(Transacts, {ReqKey, {replied, HandlerPid}}),
    {noreply, State};
handle_info({discarded, ReqKey}, State = #state{transacts = Transacts}) ->
    ets:delete(Transacts, ReqKey),
    {noreply, State};
handle_info({'EXIT', _HandlerPid, normal}, State) ->
    {noreply, State};
handle_info({'EXIT', HandlerPid, _OtherReason}, State = #state{transacts = Transacts}) ->
    ets:match_delete(Transacts, {'_', {'_', HandlerPid}}),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, State) ->
    gen_udp:close(State#state.socket),
    ok.

%% @private
handle_call({stats, pull}, _From, State = #state{counter = Counter}) ->
    {reply, Counter, State#state{counter = eradius_counter:reset_counter(Counter)}};
handle_call({stats, read}, _From, State = #state{counter = Counter}) ->
    {reply, Counter, State};
handle_call({stats, reset}, _From, State = #state{counter = Counter}) ->
    {reply, ok, State#state{counter = eradius_counter:reset_counter(Counter)}}.

%% -- unused callbacks
%% @private
handle_cast(_Msg, State)            -> {noreply, State}.
%% @private
code_change(_OldVsn, State, _Extra) -> {ok, State}.

-spec lookup_nas(#state{}, inet:ip_address(), binary()) -> {ok, req_id(), eradius_server_mon:handler(), #nas_prop{}} | {discard, unknown_nas | bad_pdu}.
lookup_nas(#state{ip = IP, port = Port}, NasIP, <<_Code, ReqID, _/binary>>) ->
    case eradius_server_mon:lookup_handler(IP, Port, NasIP) of
        {ok, Handler, NasProp} ->
            {ok, ReqID, Handler, NasProp};
        {error, not_found} ->
            {discard, unknown_nas}
    end;
lookup_nas(_State, _NasIP, _Packet) ->
    {discard, bad_pdu}.

%% ------------------------------------------------------------------------------------------
%% -- Request Handler

%% @private
-spec do_radius_queue(name(), pid(), term(), eradius_server_mon:handler(), #nas_prop{}, udp_packet()) -> any().
do_radius_queue(Name, ServerPid, ReqKey, Handler, NasProp, ReqUDP) ->
    case jobs:ask(Name) of
        {ok, Opaque} ->
            MayBeResend = (catch do_radius(ServerPid, ReqKey, Handler, NasProp, ReqUDP)),
            jobs:done(Opaque),
            is_function(MayBeResend) andalso MayBeResend();
        {error, _Reason} ->
            eradius_counter:inc_counter(packetsDropped, NasProp)
    end.

%% @private
do_radius(ServerPid, ReqKey, Handler = {HandlerMod, _}, NasProp, {udp, Socket, FromIP, FromPort, EncRequest}) ->
    Nodes = eradius_node_mon:get_module_nodes(HandlerMod),
    case run_handler(Nodes, NasProp, Handler, EncRequest) of
        {reply, EncReply} ->
            dbg(NasProp, "sending response for ~p~n", [ReqKey]),
            gen_udp:send(Socket, FromIP, FromPort, EncReply),
            ServerPid ! {replied, ReqKey, self()},
            eradius_counter:inc_counter(replies, NasProp),
            {ok, ResendTimeout} = application:get_env(eradius, resend_timeout),
            fun() -> wait_resend_init(ServerPid, ReqKey, FromIP, FromPort, EncReply, ResendTimeout, ?RESEND_RETRIES) end;
        {discard, Reason} ->
            dbg(NasProp, "discarding request ~p: ~1000.p~n", [ReqKey, Reason]),
            discard_inc_counter(Reason, NasProp),
            ServerPid ! {discarded, ReqKey};
        {exit, Reason} ->
            dbg(NasProp, "discarding request (handler EXIT) ~p: ~p~n", [ReqKey, Reason]),
            eradius_counter:inc_counter(handlerFailure, NasProp),
            ServerPid ! {discarded, ReqKey}
    end.

%% @TODO: extend for other failures
discard_inc_counter(bad_pdu, NasProp) ->
    eradius_counter:inc_counter(malformedRequests, NasProp);
discard_inc_counter(_Reason, NasProp) ->
    eradius_counter:inc_counter(packetsDropped, NasProp).

wait_resend_init(ServerPid, ReqKey, FromIP, FromPort, EncReply, ResendTimeout, Retries) ->
    erlang:send_after(ResendTimeout, self(), timeout),
    wait_resend(ServerPid, ReqKey, FromIP, FromPort, EncReply, Retries).

wait_resend(ServerPid, ReqKey, _FromIP, _FromPort, _EncReply, 0) ->
    ServerPid ! {discarded, ReqKey};
wait_resend(ServerPid, ReqKey, FromIP, FromPort, EncReply, Retries) ->
    receive
        {ServerPid, resend, Socket} ->
            gen_udp:send(Socket, FromIP, FromPort, EncReply),
            wait_resend(ServerPid, ReqKey, FromIP, FromPort, EncReply, Retries - 1);
        timeout ->
            ServerPid ! {discarded, ReqKey}
    end.

run_handler([], _NasProp, _Handler, _EncRequest) ->
    {discard, no_nodes};
run_handler(NodesAvailable, NasProp = #nas_prop{handler_nodes = local}, Handler, EncRequest) ->
    case lists:member(node(), NodesAvailable) of
        true ->
            handle_request(Handler, NasProp, EncRequest);
        false ->
            {discard, no_nodes_local}
    end;
run_handler(NodesAvailable, NasProp, Handler, EncRequest) ->
    case ordsets:intersection(lists:usort(NodesAvailable), lists:usort(NasProp#nas_prop.handler_nodes)) of
        [LocalNode] when LocalNode == node() ->
            handle_request(Handler, NasProp, EncRequest);
        [RemoteNode] ->
            run_remote_handler(RemoteNode, Handler, NasProp, EncRequest);
        Nodes ->
            %% humble testing at the erlang shell indicated that phash2 distributes N
            %% very well even for small lenghts.
            N = erlang:phash2(make_ref(), length(Nodes)) + 1,
            case lists:nth(N, Nodes) of
                LocalNode when LocalNode == node() ->
                    handle_request(Handler, NasProp, EncRequest);
                RemoteNode ->
                    run_remote_handler(RemoteNode, Handler, NasProp, EncRequest)
            end
    end.

run_remote_handler(Node, {HandlerMod, HandlerArgs}, NasProp, EncRequest) ->
    NasPropTuple = nas_prop_record_to_tuple(NasProp),
    RemoteArgs = [self(), HandlerMod, HandlerArgs, NasPropTuple, EncRequest],
    HandlerPid = spawn_link(Node, ?MODULE, handle_remote_request, RemoteArgs),
    receive
        {HandlerPid, ReturnValue} ->
            ReturnValue
    after
        ?HANDLER_REPLY_TIMEOUT ->
            %% this happens if the remote handler doesn't terminate
            unlink(HandlerPid),
            {discard, {remote_handler_reply_timeout, Node}}
    end.

%% @private
-spec handle_request(eradius_server_mon:handler(), #nas_prop{}, binary()) -> any().
handle_request({HandlerMod, HandlerArg}, NasProp, EncRequest) ->
    case eradius_lib:decode_request(EncRequest, NasProp#nas_prop.secret) of
        Request = #radius_request{} ->
            request_inc_counter(Request#radius_request.cmd, NasProp),
            Sender = {NasProp#nas_prop.nas_ip, NasProp#nas_prop.nas_port, Request#radius_request.reqid},
            eradius_log:write_request(Sender, Request),
            apply_handler_mod(HandlerMod, HandlerArg, Request, NasProp);
        bad_pdu ->
            {discard, bad_pdu}
    end.

%% @private
%% @doc this function is spawned on a remote node to handle a radius request.
%%   remote handlers need to be upgraded if the signature of this function changes.
%%   error reports go to the logger of the node that executes the request.
handle_remote_request(ReplyPid, HandlerMod, HandlerArg, NasPropTuple, EncRequest) ->
    group_leader(whereis(user), self()),
    NasProp = nas_prop_tuple_to_record(NasPropTuple),
    Result = handle_request({HandlerMod, HandlerArg}, NasProp, EncRequest),
    ReplyPid ! {self(), Result}.

nas_prop_record_to_tuple(R = #nas_prop{}) ->
    {nas_prop_v1, R#nas_prop.server_ip, R#nas_prop.server_port,
                  R#nas_prop.nas_ip, R#nas_prop.nas_port,
                  R#nas_prop.secret, R#nas_prop.trace, R#nas_prop.handler_nodes}.

nas_prop_tuple_to_record({nas_prop_v1, ServerIP, ServerPort, NasIP, NasPort, Secret, Trace, Nodes}) ->
    #nas_prop{server_ip = ServerIP, server_port = ServerPort,
              nas_ip = NasIP, nas_port = NasPort,
              secret = Secret, trace = Trace, handler_nodes = Nodes}.

-spec apply_handler_mod(module(), term(), #radius_request{}, #nas_prop{}) -> {discard, term()} | {exit, term()} | {reply, binary()}.
apply_handler_mod(HandlerMod, HandlerArg, Request, NasProp) ->
    try HandlerMod:radius_request(Request, NasProp, HandlerArg) of
        {reply, Reply = #radius_request{cmd = ReplyCmd, attrs = ReplyAttrs, msg_hmac = MsgHMAC, eap_msg = EAPmsg}} ->
            Sender = {NasProp#nas_prop.nas_ip, NasProp#nas_prop.nas_port, Request#radius_request.reqid},
            EncReply = eradius_lib:encode_reply_request(Request#radius_request{cmd = ReplyCmd, attrs = ReplyAttrs,
									       msg_hmac = Request#radius_request.msg_hmac or MsgHMAC or (size(EAPmsg) > 0),
									       eap_msg = EAPmsg}),
            reply_inc_counter(ReplyCmd, NasProp),
            eradius_log:write_request(Sender, Reply),
            {reply, EncReply};
        noreply ->
            {discard, handler_returned_noreply};
        OtherReturn ->
            error_logger:error_report([radius_handler, {type, bad_return},
                                                       {return, OtherReturn}]),
            {discard, {bad_return, OtherReturn}}
    catch
        Class:Reason ->
            error_logger:error_report([radius_handler, {type, 'CRASH'},
                                                       {class, Class},
                                                       {reason, Reason},
                                                       {stacktrace, erlang:get_stacktrace()}]),
            {exit, {Class, Reason}}
    end.

-spec dbg(#nas_prop{}, string(), list()) -> ok.
dbg(#nas_prop{trace = true}, Fmt, Vals) ->
    io:put_chars([printable_date(), " -- ", io_lib:format(Fmt, Vals)]);
dbg(_, _, _) ->
    ok.

-spec printable_date() -> io_lib:chars().
printable_date() ->
    {_ , _, MicroSecs} = Now = now(),
    {{Y, Mo, D}, {H, M, S}} = calendar:now_to_local_time(Now),
    io_lib:format("~4..0b-~2..0b-~2..0b ~2..0b:~2..0b:~2..0b:~4..0b", [Y,Mo,D,H,M,S,MicroSecs div 1000]).

request_inc_counter(request, NasProp) ->
    eradius_counter:inc_counter(accessRequests, NasProp);
request_inc_counter(accreq, NasProp) ->
    eradius_counter:inc_counter(accountRequests, NasProp);
request_inc_counter(coareq, NasProp) ->
    eradius_counter:inc_counter(coaRequests, NasProp);
request_inc_counter(discreq, NasProp) ->
    eradius_counter:inc_counter(disconnectRequests, NasProp);
request_inc_counter(_Cmd, _NasProp) ->
    ok.

reply_inc_counter(accept, NasProp) ->
    eradius_counter:inc_counter(accessAccepts, NasProp);
reply_inc_counter(reject, NasProp) ->
    eradius_counter:inc_counter(accessRejects, NasProp);
reply_inc_counter(challenge, NasProp) ->
    eradius_counter:inc_counter(accessChallenges, NasProp);
reply_inc_counter(accresp, NasProp) ->
    eradius_counter:inc_counter(accountResponses, NasProp);
reply_inc_counter(coaack, NasProp) ->
    eradius_counter:inc_counter(coaAcks, NasProp);
reply_inc_counter(coanak, NasProp) ->
    eradius_counter:inc_counter(coaNaks, NasProp);
reply_inc_counter(discack, NasProp) ->
    eradius_counter:inc_counter(discAcks, NasProp);
reply_inc_counter(discnak, NasProp) ->
    eradius_counter:inc_counter(discNaks, NasProp);
reply_inc_counter(_Cmd, _NasProp) ->
    ok.
