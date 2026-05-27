interface packet_if #(parameter int FLIT_WIDTH = 64) (input logic clk, rst_n);

    import switch_pkg::*;


    logic                    valid;
    logic                    ready;
    logic [FLIT_WIDTH-1:0]   data;
    logic                    sop;
    logic                    eop;
    priority_t               priority;

    modport master (
        input ready,
        output valid, data, sop, eop, priority
    );

    modport slave (
        input valid, data, sop, eop, priority,
        output ready
    );

    clocking master_cb @(posedge clk);
        default input #1 output #1;
        input ready;
        output valid, data, sop, eop, priority;
    endclocking


    clocking monitor_cb @(posedge clk);
        default input #1;
        input valid, ready, data, sop, eop, priority;
    endclocking

endinterface : packet_if
