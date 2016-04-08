// Author: Joshua Reed
// Class:  ECE 272, Spring 2016
// File: volt_meter.sv
// Description: 
// Full unipolar volt meter implementation.
// spi_master is instantiated to communicate with the AD7705. 
// A state machine is then used to setup and poll the ADC for 
// voltage readings. 
// The voltage that can be measured by default is 0-5V due to the layout of
// the AD7705 board, and the default gain settings. 


//==========================================
//=============================== top ======
//==========================================
module Sev_Seg( input  logic                reset, 
                input  logic                MISO, drdy,
                output logic unsigned [6:0] LEDs, 
                output logic          [2:0] sel, 
                output logic                MOSI, adc_reset, CS, SCK );
    
    logic done;
    logic clk_2Mhz;
    logic clk_500hz;
    logic transmit;
    logic unsigned [7:0] to_send;
    logic unsigned [3:0] cnt;
    logic unsigned [15:0] temp_data, data;
    logic [7:0] data_byte;
    enum{CONFIGURE, POLL_DRDY, RQST_DATA, READ_DATA1, READ_DATA2} state;

    // Set Oscillator
    defparam OSCH_inst.NOM_FREQ = "2.08";

    // Instantiate Oscillator
    OSCH OSCH_inst( .STDBY ( 0        ),
                    .OSC   ( clk_2Mhz ) );

    clk_cntr cc1 ( // Data update clock counter
       .reset    ( reset     ),
       .cnt_to   ( 260000    ), // 2.08Mhz / 260000 = 8hz
       .clk      ( clk_2Mhz  ),
       .clk_o    ( clk_4hz   ) );

    clk_cntr cc2 ( // Clock Counter
       .reset    ( reset     ),
       .cnt_to   ( 4150      ), // 2.08Mhz / 8 = ~500hz
       .clk      ( clk_2Mhz  ),
       .clk_o    ( clk_500hz ) );

    seg_driver disp ( 
        .clk        ( clk_500hz ), 
        .reset      ( reset     ),
        .num        ( data      ),
        .strobe     ( 1'b1      ),
        .LEDs       ( LEDs      ), 
        .sel        ( sel       ) );
    
    always_ff @(posedge clk_4hz, negedge reset) 
        if (~reset) data <= 0;
        else data <= (temp_data*1000)/13107;

    
   /* == States ============================= 
    *
    *      -- ( Setup ) --
    *
    * The states should progress as:
    * 1)    a) Reset AD7705
    *                -- Set AD7705 reset to 0 then
    *                -- Set AD7705 reset to 1 
    *       b) Write to comms register to select channel and 
    *          set next opperation to be a write to the clock register.
    *          See p16 of the datasheet for bit definitions.
    *                -- Send 00100000(32) over spi
    *       c) Write to clock register to set master clock reference, 
    *          and desired update rate(50Hz). 
    *          The board designed by TekBots uses a 4.192MHz oscillator.
    *          The slowest setting posible is 50Hz.
    *          See p19 of the datasheet for bit definitions.
    *                -- Send 00001100(12) over spi
    *       d) Write to comms register to select channel and 
    *          set next opperation to be a write to the setup register.
    *                -- Send 00010000(16) over spi 
    *       d) Write to setup register to set gain, op conditions and
    *          initiate a self-calibration.
    *          See p17 of the datasheet for bit definitions.
    *                -- Send 01000100(68)
    *
    *      -- ( Operational Cycle ) --
    *
    * 6) Begin Opperational Cycle
    *          -- IF DRDY pin == 0 transition
    * 7) Write to comms register to set up next operation as
    *    a read from the data register.
    *          -- Send 00111000(56) over spi
    * 8) Read from data register.
    *          -- Read spi data for 8 bits
    * 9) Read from data register.
    *          -- Read spi data for another 8 bits
    *          -- GoTo 6
    *
    * See p33 of the datasheet for state diagram.
    */
    always_ff @(posedge clk_2Mhz, negedge reset) begin : adc_sm
        logic prev_done;
        if (~reset) begin 
            state <= CONFIGURE;
            cnt <= 3000;
            transmit <= 0;
            to_send <= 32;
            prev_done <= 0;
            adc_reset <= 0;
            end
        else begin
            adc_reset <= 1;
            case(state)
                CONFIGURE : begin
                    // Reset ADC
                    if (cnt==1500) adc_reset <= 1;
                    if (cnt>4) cnt <= cnt-1;
                    else if(done && (prev_done != done)) begin
                        if(cnt==4)to_send <= 12;
                        if(cnt==3)to_send <= 16;
                        if(cnt==2)to_send <= 68;
                        cnt <= cnt-1;
                        transmit <= 0;
                        end
                    else transmit <= 1; 

                    // Transition State
                    if(cnt==0) begin
                        state <= POLL_DRDY;
                        transmit <= 0;
                        end
                    end
                POLL_DRDY : begin
                        if (~drdy) state <= RQST_DATA;
                        to_send  <= 56; // read
                        transmit <= 0;
                        end
                RQST_DATA : begin
                    transmit <= 1; 
                    if (done && prev_done!=done) begin
                        state    <= READ_DATA1;
                        transmit <= 0;
                        end
                    end
                READ_DATA1 : begin
                    transmit <= 1; 
                    if (done && prev_done!=done) begin
                        transmit  <= 0;
                        state     <= READ_DATA2;
                        temp_data[15:8] <= data_byte;
                        end
                    end
                READ_DATA2 : begin
                    transmit <= 1; 
                    if (done && prev_done!=done) begin
                        transmit <= 0;
                        state    <= POLL_DRDY;
                        temp_data[7:0] <= data_byte;
                        end
                    end
                default : state <= CONFIGURE;
                endcase
            prev_done <= done;
            end
        end
    
    //assign CS = ~transmit;
    assign CS = 0;

    /* To use, load 'to_send' with a byte of data while holding 'transmit' low. 
    *  Then switch 'transmit' high. 
    *  The byte will be sent over the next 16 clk cycles 
    *  'done' will go high upon completion. 
    *  To clear done pull transmit to low.
    *  MISO -> Master In Slave Out
    *  MOSI -> Master Out Slave In
    *  SCK  -> Serial Shift Clock
    */ 
    spi_master spi (
        // inputs
        .clk       ( clk_2Mhz ),
        .reset     ( reset      ),
        .MISO      ( MISO       ),
        .transmit  ( transmit   ),
        .to_send   ( to_send    ),
        // outputs
        .MOSI      ( MOSI      ),
        .SCK       ( SCK       ),
        .received  ( data_byte ), 
        .done      ( done      ) );

    endmodule

//==========================================
//============================== clk_cntr ==
//==========================================
module clk_cntr( input  logic reset, clk,
                 input  int   cnt_to,
                 output logic clk_o );

    logic unsigned [20:0] cnt;

    always_ff @(posedge clk, negedge reset) 
        if (~reset) begin
            clk_o <= 0;
            cnt <= 0; 
            end
        else if (cnt >= cnt_to) begin
            clk_o <= ~clk_o;
            cnt <= 0; 
            end
        else cnt <= cnt+1;

    endmodule


//==========================================
//============================ seg_driver ==
//==========================================
module seg_driver( input  logic                 clk, reset, strobe,
                   input  logic unsigned [15:0] num,
                   output logic unsigned [6:0]  LEDs, 
                   output logic          [2:0]  sel );

    logic unsigned [3:0] segs [3:0];
    logic [1:0] state, next_state;
    
    //== Digit Parsing ======================
    // Includes a check for numbers above
    // what can be displayed
    // Also incorporates a strobe 
    always_ff @(posedge clk, negedge reset) 
        if (~reset) segs <= '{default:'0};
        else 
            if (strobe)
                if (num > 9999) segs <= '{default:'{default:9}};
                else begin
                    segs[0] <=  num      % 10;
                    segs[1] <= (num/10)  % 10;
                    segs[2] <= (num/100) % 10;
                    segs[3] <=  num/1000;
                    end

    //== Seg Decoding =======================
    // Digit multiplexing is done by dereferencing
    // the segs array with the value of state.
    always_comb
	    case( segs[state] ) //GFE_DCBA
            0:        LEDs=7'b100_0000;
            1:        LEDs=7'b111_1001;
            2:        LEDs=7'b010_0100;
            3:        LEDs=7'b011_0000;
            4:        LEDs=7'b001_1001;
            5:        LEDs=7'b001_0010;
            6:        LEDs=7'b000_0010;
            7:        LEDs=7'b111_1000;
            8:        LEDs=7'b000_0000;
            9:        LEDs=7'b001_1000;
            default:  LEDs=7'b100_0000;
            endcase

    //== State ==============================
    // 4 states total - one for each digit
    always_ff @(posedge clk, negedge reset) 
        if (~reset) state <= 00;
        else        state <= next_state;

    always_comb
        case(state)
            0: next_state=2'b01;
            1: next_state=2'b10;
            2: next_state=2'b11;
            3: next_state=2'b00;
            default: next_state=00;
            endcase

    //== Digit Selects =======================
    always_comb
        case(state)
            0: sel=3'b000;
            1: sel=3'b001;
            2: sel=3'b011;
            3: sel=3'b100;
            default: sel=3'b000;
            endcase

    endmodule






















