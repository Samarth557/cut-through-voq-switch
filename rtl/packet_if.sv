//==============================================================================
// File: packet_if.sv
// Project: Cut-Through VOQ Switch
// Author: Samarth Gupta
// Date: 2026-05-27
//
// Description:
//   SystemVerilog interface for flit-based packet streaming between switch
//   modules. Implements a VALID/READY handshake for backpressure support.
//
// Features:
//   - VALID/READY handshake — transfer occurs only when both are high
//   - SOP/EOP markers — identifies first and last flit of every packet
//   - pkt_priority field — valid on SOP flit, carries QoS level
//   - Master modport — for driving side (ingress ports, cut-through ctrl)
//   - Slave modport  — for receiving side (VOQ buffer, egress ports)
//   - Clocking blocks — master_cb and monitor_cb for UVM driver/monitor
//
// Flit format (header flit):
//   [63:56] dest_addr    — destination address (TCAM lookup key MSBs)
//   [55:54] pkt_priority — QoS priority (0=lowest, 3=highest)
//   [53:32] reserved
//   [31:16] length       — packet length in flits
//   [15:0]  reserved
//==============================================================================

interface packet_if #(parameter int FLIT_WIDTH = 64) (input logic clk, rst_n);

    logic                    valid;
    logic                    ready;
    logic [FLIT_WIDTH-1:0]   data;
    logic                    sop;
    logic                    eop;
    switch_pkg::priority_t   pkt_priority;

    modport master (
        input ready,
        output valid, data, sop, eop, pkt_priority
    );

    modport slave (
        input valid, data, sop, eop, pkt_priority,
        output ready
    );

    clocking master_cb @(posedge clk);
        default input #1 output #1;
        input ready;
        output valid, data, sop, eop, pkt_priority;
    endclocking


    clocking monitor_cb @(posedge clk);
        default input #1;
        input valid, ready, data, sop, eop, pkt_priority;
    endclocking

endinterface : packet_if
