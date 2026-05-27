package switch_pkg;

//Port names
typedef enum logic [1:0] { 
    PORT_0 = 2'd0,
    PORT_1 = 2'd1,
    PORT_2 = 2'd2,
    PORT_3 = 2'd3
} port_id_t;

//Priority levels
typedef enum logic [1:0] { 
    PRI_0 = 2'd0,
    PRI_1 = 2'd1,
    PRI_2 = 2'd2,
    PRI_3 = 2'd3
} priority_t;

//Mode of Fowarding 
typedef enum logic { 
    STORE_FWD = 1'b0,
    CUT_THROUGH = 1'b1
} fwd_mode_t;

//Parsed header struct
typedef struct packed {
    logic [7:0] dest_port;
    priority_t pkt_priority;
    logic [15:0] length;
} pkt_header_t;

//Parameters
parameter int FLIT_WIDTH = 64;
parameter int VOQ_DEPTH = 16;
parameter int NUM_PORTS = 4;


endpackage