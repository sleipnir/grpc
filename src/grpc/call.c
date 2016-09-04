#include <grpc/grpc.h>
#include "erl_nif.h"
#include "grpc_nifs.h"
#include "utils.h"

ERL_NIF_TERM nif_call_create7(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
  grpc_call *call = NULL;
  grpc_call *parent_call = NULL;
  wrapped_grpc_channel *wrapped_channel;
  wrapped_grpc_completion_queue *wrapped_cq;
  gpr_timespec deadline;
  char *method = NULL;
  char *host = NULL;
  int flags = GRPC_PROPAGATE_DEFAULTS;
  ErlNifSInt64 timeout;

  if (!enif_get_resource(env, argv[0], grpc_channel_resource, (void **)&wrapped_channel)) {
    return enif_raise_exception_compat(env, "Channel is not a handle to the right resource object.");
  }
  if (!enif_get_resource(env, argv[3], grpc_completion_queue_resource, (void **)&wrapped_cq)) {
    return enif_raise_exception_compat(env, "CompletionQueue is not a handle to the right resource object.");
  }
  if (!better_get_string(env, argv[4], &method)) {
    return enif_raise_exception_compat(env, "method is invalid!");
  }
  // if (!better_get_string(env, argv[5], &host)) {
  //   return enif_raise_exception_compat(env, "host is invalid!");
  // }

  if (enif_get_int64(env, argv[6], &timeout)) {
    deadline = gpr_time_from_seconds((int64_t)timeout, GPR_CLOCK_REALTIME);
  } else {
    return enif_raise_exception_compat(env, "timeout is invalid!");
  }

  call = grpc_channel_create_call(wrapped_channel->channel, parent_call, flags, wrapped_cq->cq, method, host, deadline, NULL);

  if (call == NULL) {
    enif_raise_exception_compat(env, "Could not create call.");
    return ERL_NIL;
  }

  return enif_make_resource(env, call);
}