#include <config.h>
#undef NDEBUG
#include "jsonrpc.h"
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include "command-line.h"
#include "daemon.h"
#include "fatal-signal.h"
#include "openvswitch/dynamic-string.h"
#include "openvswitch/json.h"
#include "openvswitch/poll-loop.h"
#include "openvswitch/vlog.h"
#include "ovstest.h"
#include "stream-ssl.h"
#include "stream.h"
#include "timeval.h"
#include "util.h"

OVS_NO_RETURN static void usage(void);
static void parse_options(int argc, char *argv[]);
static struct ovs_cmdl_command *get_all_commands(void);

VLOG_DEFINE_THIS_MODULE(jsonrpc_benchmark);

static void
test_jsonrpc_benchmark_main(int argc, char *argv[])
{
    struct ovs_cmdl_context ctx = { .argc = 0, };
    ovs_cmdl_proctitle_init(argc, argv);
    set_program_name(argv[0]);
    service_start(&argc, &argv);
    fatal_ignore_sigpipe();
    parse_options(argc, argv);
    ctx.argc = argc - optind;
    ctx.argv = argv + optind;
    ovs_cmdl_run_command(&ctx, get_all_commands());
}

static void
parse_options(int argc, char *argv[])
{
    enum {
        OPT_BOOTSTRAP_CA_CERT = UCHAR_MAX + 1,
        SSL_OPTION_ENUMS,
    };
    static const struct option long_options[] = {
        {"verbose", optional_argument, NULL, 'v'},
        {"help", no_argument, NULL, 'h'},
        {"bootstrap-ca-cert", required_argument, NULL, OPT_BOOTSTRAP_CA_CERT},
        STREAM_SSL_LONG_OPTIONS,
        {NULL, 0, NULL, 0},
    };
    char *short_options = ovs_cmdl_long_options_to_short_options(long_options);

    for (;;) {
        int c = getopt_long(argc, argv, short_options, long_options, NULL);
        if (c == -1) {
            break;
        }

        switch (c) {
        case 'h':
            usage();

        case 'v':
            vlog_set_verbosity(optarg);
            break;

        STREAM_SSL_OPTION_HANDLERS

        case OPT_BOOTSTRAP_CA_CERT:
            stream_ssl_set_ca_cert_file(optarg, true);
            break;

        case '?':
            exit(EXIT_FAILURE);

        default:
            abort();
        }
    }
    free(short_options);
}

static void
usage(void)
{
    printf("%s: JSON-RPC benchmark utility\n"
           "usage: %s [OPTIONS] COMMAND [ARG...]\n"
           "  server REMOTE SIZE   start a server listening on REMOTE\n"
           "  client REMOTE SIZE   start a client connecting to REMOTE\n"
           "     In both cases SIZE is the size of the message to broadcast\n",
           program_name, program_name);
    stream_usage("JSON-RPC", true, true, true);
    vlog_usage();
    printf("\nOther options:\n"
           "  -h, --help                  display this help message\n");
    exit(EXIT_SUCCESS);
}


static struct json *
get_expected(int n)
{
    struct ds ds = DS_EMPTY_INITIALIZER;
    struct json *expected;
    int c = 0;

    for (int i = 0; i < n; i++) {
        ds_put_char(&ds, '0' + c++ % 10);
    }

    expected = json_string_create(ds_cstr_ro(&ds));
    ds_destroy(&ds);

    return expected;
}

static void
do_client(struct ovs_cmdl_context *ctx)
{
    struct json *expected, *got;
    struct jsonrpc_msg *msg;
    struct jsonrpc *rpc;
    struct stream *stream;
    int error;

    error = stream_open_block(jsonrpc_stream_open(ctx->argv[1], &stream,
                              DSCP_DEFAULT), -1, &stream);
    if (error) {
        VLOG_FATAL("could not open \"%s\"", ctx->argv[1]);
    }

    expected = get_expected(atoi(ctx->argv[2]));

    rpc = jsonrpc_open(stream);

    for (;;) {
        error = jsonrpc_recv_block(rpc, &msg);
        if (error) {
            VLOG_FATAL("error waiting for reply: %s", ovs_strerror(error));
        }
        got = json_array(msg->params)->elems[0];
        if (!json_equal(got, expected)) {
            VLOG_FATAL("Corruption!\nExpected:\n%s\nGot:\n%s\n",
                       json_to_string(expected, JSSF_SORT),
                       json_to_string(got, JSSF_SORT));
        }
        jsonrpc_msg_destroy(msg);
    }

    jsonrpc_close(rpc);
}

static void
do_server(struct ovs_cmdl_context *ctx)
{
    struct pstream *pstream;
    struct jsonrpc **rpcs;
    struct json *expected;
    size_t n_rpcs, allocated_rpcs;
    int error;

    error = jsonrpc_pstream_open(ctx->argv[1], &pstream, DSCP_DEFAULT);
    if (error) {
        VLOG_FATAL("could not listen on \"%s\": %s",
                   ctx->argv[1], ovs_strerror(error));
    }

    expected = get_expected(atoi(ctx->argv[2]));

    rpcs = NULL;
    n_rpcs = allocated_rpcs = 0;
    for (;;) {
        struct stream *stream;
        size_t i;

        /* Accept new connections. */
        error = pstream_accept(pstream, &stream);
        if (!error) {
            if (n_rpcs >= allocated_rpcs) {
                rpcs = x2nrealloc(rpcs, &allocated_rpcs, sizeof *rpcs);
            }
            rpcs[n_rpcs++] = jsonrpc_open(stream);
        } else if (error != EAGAIN) {
            VLOG_FATAL("pstream_accept failed: %s", ovs_strerror(error));
        }

        /* Service existing connections. */
        for (i = 0; i < n_rpcs; ) {
            struct jsonrpc *rpc = rpcs[i];
            struct jsonrpc_msg *msg;

            error = 0;
            jsonrpc_run(rpc);
            if (!jsonrpc_get_backlog(rpc)) {
                msg = jsonrpc_create_notify(
                        "test-benchmark",
                        json_array_create_1(json_clone(expected)));
                error = jsonrpc_send(rpc, msg);
            }

            if (!error) {
                error = jsonrpc_get_status(rpc);
            }
            if (error) {
                VLOG_WARN("connection closed (%s): %s",
                          jsonrpc_get_name(rpc), ovs_strerror(error));
                jsonrpc_close(rpc);
                memmove(&rpcs[i], &rpcs[i + 1],
                        (n_rpcs - i - 1) * sizeof *rpcs);
                n_rpcs--;
            } else {
                i++;
            }
        }

        if (!n_rpcs) {
            poll_timer_wait(100);
        } else {
            poll_immediate_wake();
        }
        poll_block();
    }
    free(rpcs);
    pstream_close(pstream);
}

static void
do_help(struct ovs_cmdl_context *ctx OVS_UNUSED)
{
    usage();
}

static struct ovs_cmdl_command all_commands[] = {
    { "server", NULL, 2, 2, do_server, OVS_RO },
    { "client", NULL, 2, 2, do_client, OVS_RO },
    { "help", NULL, 0, INT_MAX, do_help, OVS_RO },
    { NULL, NULL, 0, 0, NULL, OVS_RO },
};

static struct ovs_cmdl_command *
get_all_commands(void)
{
    return all_commands;
}

OVSTEST_REGISTER("test-jsonrpc-benchmark", test_jsonrpc_benchmark_main);
