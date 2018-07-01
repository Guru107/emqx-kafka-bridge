%%--------------------------------------------------------------------
%% Copyright (c) 2015-2017 Feng Lee <feng@emqtt.io>.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emq_kafka_bridge).

-include("emq_kafka_bridge.hrl").

-include_lib("emqttd/include/emqttd.hrl").

-include_lib("emqttd/include/emqttd_protocol.hrl").

-include_lib("emqttd/include/emqttd_internal.hrl").

-import(string,[concat/2]).
-import(lists,[nth/2]). 


-export([load/1, unload/0]).

%% Hooks functions

-export([on_client_connected/3, on_client_disconnected/3]).

% -export([on_client_subscribe/4, on_client_unsubscribe/4]).

% -export([on_session_created/3, on_session_subscribed/4, on_session_unsubscribed/4, on_session_terminated/4]).

-export([on_message_publish/2, on_message_delivered/4, on_message_acked/4]).


%% Called when the plugin application start
load(Env) ->
	ekaf_init([Env]),
    emqttd:hook('client.connected', fun ?MODULE:on_client_connected/3, [Env]),
    emqttd:hook('client.disconnected', fun ?MODULE:on_client_disconnected/3, [Env]),
    emqttd:hook('message.publish', fun ?MODULE:on_message_publish/2, [Env]),
    emqttd:hook('message.delivered', fun ?MODULE:on_message_delivered/4, [Env]),
    emqttd:hook('message.acked', fun ?MODULE:on_message_acked/4, [Env]).

on_client_connected(ConnAck, Client = #mqtt_client{client_id = ClientId}, _Env) ->
    % io:format("client ~s connected, connack: ~w~n", [ClientId, ConnAck]),
    Message = mochijson2:encode([{status, <<"connected">>},
                                    {deviceId, ClientId}]),
    produce_kafka_event(Message),
    {ok, Client}.

on_client_disconnected(Reason, _Client = #mqtt_client{client_id = ClientId}, _Env) ->
    % io:format("client ~s disconnected, reason: ~w~n", [ClientId, Reason]),
    Message = mochijson2:encode([
        {status, <<"disconnected">>},
        {deviceId, ClientId}]),
    produce_kafka_event(Message),
    ok.

%% transform message and return
on_message_publish(Message = #mqtt_message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(Message = #mqtt_message{topic = Topic}, _Env) ->
    % From = Message#mqtt_message.from,
    {ClientId, Username} = Message#mqtt_message.from,
    % Payload = Message#mqtt_message.payload,
    % io:format("client(~s/~s) publish message to topic: ~s~n", [ClientId, Username, Topic]),
    Payload = mochijson2:encode([
                                {topic, Message#mqtt_message.topic},
                                {deviceId, ClientId},
								{username, Username},							  	
							  	{payload, Message#mqtt_message.payload}]),
    produce_kafka_payload(Payload),	
    {ok, Message}.
    % lager:info("client(~s/~s) publish message to topic: ~s.", [ClientId, Username, Topic]),
    % Dup = Message#mqtt_message.dup,
    % Retain = Message#mqtt_message.retain,
    % Qos = Message#mqtt_message.qos,
    % Pktid = Message#mqtt_message.pktid,
    % Str0 = <<"{\"topic\":\"">>,
    % Str1 = <<"\", \"deviceId\":\"">>,
    % Str2 = <<"\", \"payload\":[">>,
    % Str3 = <<"]}">>,
    % Str4 = <<Str0/binary, Topic/binary, Str1/binary, ClientId/binary, Str2/binary, Payload/binary, Str3/binary>>,
	% {ok, KafkaTopic} = application:get_env(emq_kafka_bridge, values),
    % ProduceTopic = proplists:get_value(kafka_payload_producer_topic, KafkaTopic),
    % ekaf:produce_async(ProduceTopic, Str4),
    % Payload = mochijson2:encode([{deviceId, ClientId},
	% 							{username, Username},
	% 						  	{topic, Message#mqtt_message.topic},
	% 						  	{payload, Message#mqtt_message.payload}]),
    % produce_kafka_payload(Payload),	
    % {ok, Message}.


on_message_delivered(ClientId, Username, Message, _Env) ->
    % io:format("delivered to client(~s/~s): ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
    {ok, Message}.

on_message_acked(ClientId, Username, Message, _Env) ->
    % io:format("client(~s/~s) acked: ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
    {ok, Message}.

ekaf_init(_Env) ->
    {ok, BrokerValues} = application:get_env(emq_kafka_bridge, broker),
    KafkaHost = proplists:get_value(host, BrokerValues),
    KafkaPort = proplists:get_value(port, BrokerValues),
    KafkaPartitionStrategy= proplists:get_value(partitionstrategy, BrokerValues),
    application:set_env(ekaf, ekaf_bootstrap_broker,  {KafkaHost, list_to_integer(KafkaPort)}),
    application:set_env(ekaf, ekaf_partition_strategy, KafkaPartitionStrategy),
    {ok, _} = application:ensure_all_started(ekaf),
    io:format("Init ekaf server with ~s:~s, topic: ~s~n", [KafkaHost, KafkaPort, KafkaPartitionStrategy]).

%% Called when the plugin application stop
unload() ->
    emqttd:unhook('client.connected', fun ?MODULE:on_client_connected/3),
    emqttd:unhook('client.disconnected', fun ?MODULE:on_client_disconnected/3),
    % emqttd:unhook('client.subscribe', fun ?MODULE:on_client_subscribe/4),
    % emqttd:unhook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/4),
    % emqttd:unhook('session.subscribed', fun ?MODULE:on_session_subscribed/4),
    % emqttd:unhook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4),
    emqttd:unhook('message.publish', fun ?MODULE:on_message_publish/2),
    emqttd:unhook('message.delivered', fun ?MODULE:on_message_delivered/4),
    emqttd:unhook('message.acked', fun ?MODULE:on_message_acked/4).

produce_kafka_payload(Message) ->
	{ok, KafkaValue} = application:get_env(emq_kafka_bridge, broker),
	Topic = proplists:get_value(payloadtopic, KafkaValue),
	io:format("send to kafka payload topic: ~s, data: ~s~n", [Topic, Message]),
    try ekaf:produce_async(list_to_binary(Topic), list_to_binary(Message))
    catch _:Error ->
        lager:error("can't send to kafka error: ~s~n", [Error])
    end.

produce_kafka_event(Message) ->
	{ok, KafkaValue} = application:get_env(emq_kafka_bridge, broker),
	Topic = proplists:get_value(eventstopic, KafkaValue),
	io:format("send to kafka event topic: ~s, data: ~s~n", [Topic, Message]),
    try ekaf:produce_async(list_to_binary(Topic), list_to_binary(Message))
    catch _:Error ->
        lager:error("can't send to kafka error: ~s~n", [Error])
    end.