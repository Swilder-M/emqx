%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_misc).

-export([merge_opts/2, start_timer/2, start_timer/3, cancel_timer/1,
         proc_name/2, proc_stats/0, proc_stats/1, conn_proc_mng_policy/0]).

%% @doc Merge options
-spec(merge_opts(list(), list()) -> list()).
merge_opts(Defaults, Options) ->
    lists:foldl(
      fun({Opt, Val}, Acc) ->
          lists:keystore(Opt, 1, Acc, {Opt, Val});
         (Opt, Acc) ->
          lists:usort([Opt | Acc])
      end, Defaults, Options).

-spec(start_timer(integer(), term()) -> reference()).
start_timer(Interval, Msg) ->
    start_timer(Interval, self(), Msg).

-spec(start_timer(integer(), pid() | atom(), term()) -> reference()).
start_timer(Interval, Dest, Msg) ->
    erlang:start_timer(Interval, Dest, Msg).

-spec(cancel_timer(undefined | reference()) -> ok).
cancel_timer(Timer) when is_reference(Timer) ->
    case erlang:cancel_timer(Timer) of
        false ->
            receive {timeout, Timer, _} -> ok after 0 -> ok end;
        _ -> ok
    end;
cancel_timer(_) -> ok.

-spec(proc_name(atom(), pos_integer()) -> atom()).
proc_name(Mod, Id) ->
    list_to_atom(lists:concat([Mod, "_", Id])).

-spec(proc_stats() -> list()).
proc_stats() ->
    proc_stats(self()).

-spec(proc_stats(pid()) -> list()).
proc_stats(Pid) ->
    Stats = process_info(Pid, [message_queue_len, heap_size, reductions]),
    {value, {_, V}, Stats1} = lists:keytake(message_queue_len, 1, Stats),
    [{mailbox_len, V} | Stats1].

-define(DISABLED, 0).

%% @doc Check self() process status against connection/session process management policy,
%% return `continue | hibernate | {shutdown, Reason}' accordingly.
%% `continue': There is nothing out of the ordinary
%% `hibernate': Nothing to process in my mailbox (and since this check is triggered
%%              by a timer, we assume it is a fat chance to continue idel, hence hibernate.
%% `shutdown': Some numbers (message queue length or heap size have hit the limit,
%%             hence shutdown for greater good (system stability).
-spec(conn_proc_mng_policy() -> continue | hibernate | {shutdown, _}).
conn_proc_mng_policy() ->
    MaxMsgQueueLen = application:get_env(?APPLICATION, conn_max_msg_queue_len, ?DISABLED),
    Qlength = proc_info(message_queue_len),
    Checks =
        [{fun() -> is_enabled(MaxMsgQueueLen) andalso Qlength > MaxMsgQueueLen end,
          {shutdown, message_queue_too_long}},
         {fun() -> is_heap_size_too_large() end,
          {shutdown, total_heap_size_too_large}},
         {fun() -> Qlength > 0 end, continue},
         {fun() -> true end, hibernate}
        ],
    check(Checks).

check([{Pred, Result} | Rest]) ->
    case Pred() of
        true -> Result;
        false -> check(Rest)
    end.

is_heap_size_too_large() ->
    MaxTotalHeapSize = application:get_env(?APPLICATION, conn_max_total_heap_size, ?DISABLED),
    is_enabled(MaxTotalHeapSize) andalso proc_info(total_heap_size) > MaxTotalHeapSize.

is_enabled(Max) -> Max > ?DISABLED.

proc_info(Key) ->
    {Key, Value} = erlang:process_info(self(), Key),
    Value.

