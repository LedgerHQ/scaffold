// This file is part of Scaffold
//
// Scaffold is free software: you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//
// Copyright 2024 Ledger SAS, written by Charles Christen

import SWDInner::*;

import GetPut::*;
import Vector::*;
import StmtFSM::*;
import ClientServer::*;

(* always_enabled *)
interface ScaffoldBus;
    // bus_in_t
    (* prefix="" *) method Action address((* port="address" *) Bit#(16) a);
    (* prefix="" *) method Action write_data((* port="write_data" *) Bit#(8) w);
    (* prefix="" *) method Action write((* port="write" *) Bit#(1) b);
    (* prefix="" *) method Action read((* port="read" *) Bit#(1) b);

    // register selection
    (* prefix="" *) method Action en_rdata((* port="en_rdata" *) Bit#(1) en);
    (* prefix="" *) method Action en_wdata((* port="en_wdata" *) Bit#(1) en);
    (* prefix="" *) method Action en_cmd((* port="en_cmd" *) Bit#(1) en);
    (* prefix="" *) method Action en_status((* port="en_status" *) Bit#(1) en);

    // readable register out
    (* prefix="" *) method Bit#(8) reg_rdata;
    (* prefix="" *) method Bit#(8) reg_status;
endinterface

interface ScaffoldSWDModule;
    (* prefix="" *) interface ScaffoldBus bus;
    (* prefix="" *) interface SWDControllerPins pins;
endinterface

typedef struct {
    Bit#(1) reset;
    Bit#(3) reserved;
    Bit#(1) apndp;
    Bit#(1) rnw;
    Bit#(2) addr;
} Cmd deriving (Eq, Bits);

typedef enum {
    IDLE,
    RESET,
    RW
} State deriving (Eq, Bits);

(* synthesize *)
module swd_module (ScaffoldSWDModule);
    SWDController#(100) swd_controller <- mkSWDController();

    Wire#(Bit#(16)) bus_address <- mkDWire(0);
    Wire#(Bit#(8)) bus_write_data <- mkDWire(0);
    Wire#(Bit#(1)) bus_write <- mkDWire(0);
    Wire#(Bit#(1)) bus_read <- mkDWire(0);
    Wire#(Bit#(1)) bus_en_rdata <- mkDWire(0);
    Wire#(Bit#(1)) bus_en_wdata <- mkDWire(0);
    Wire#(Bit#(1)) bus_en_cmd <- mkDWire(0);
    Wire#(Bit#(1)) bus_en_status <- mkDWire(0);

    Reg#(Bit#(8)) bus_reg_rdata <- mkReg(0);
    Reg#(Bit#(8)) bus_reg_status <- mkReg(0);

    Reg#(Bit#(2)) reg_rdata_cnt <- mkReg(0);

    Reg#(Vector#(4, Bit#(8))) rdata <- mkReg(unpack(0));
    Reg#(Status) status <- mkReg(unpack(0));
    Reg#(Vector#(4, Bit#(8))) wdata <- mkReg(unpack(0));
    Reg#(Maybe#(Cmd)) cmd <- mkReg(tagged Invalid);

    Reg#(Bool) ready <- mkReg(False);
    Reg#(State) state <- mkReg(IDLE);

    rule do_bus_read (bus_read == 1);
        case ({bus_en_rdata, bus_en_status}) matches
            2'b10: 
                begin 
                    bus_reg_rdata <= rdata[reg_rdata_cnt];
                    reg_rdata_cnt <= reg_rdata_cnt + 1;
                end
            2'b01: bus_reg_status <= {pack(state == IDLE), 5'b0, pack(status)};
        endcase
    endrule

    rule do_bus_write ((bus_write == 1) && (state == IDLE));
        case ({bus_en_wdata, bus_en_cmd}) matches
            2'b10: wdata <= shiftInAt0(wdata, bus_write_data);
            2'b01: cmd <= tagged Valid(unpack(bus_write_data));
        endcase
    endrule

    rule do_ready;
        ready <= swd_controller.ready;
    endrule

    // ONLY do something if there is a valid command registered, and if
    // the user is not currently writing to some register.
    rule do_idle ((state == IDLE) && (bus_write == 0) && isValid(cmd));
        let new_cmd = fromMaybe(?, cmd);

        if (new_cmd.reset == 1) begin
            swd_controller.reset();
            state <= RESET;
        end

        else if (new_cmd.rnw == 1) begin
            swd_controller.rw.request.put(
                tagged Read { register: Register { apndp: new_cmd.apndp, addr: new_cmd.addr } }
            );
            state <= RW;
        end

        else begin
            swd_controller.rw.request.put(
                tagged Write { register: Register { apndp: new_cmd.apndp, addr: new_cmd.addr }, wdata: pack(reverse(wdata)) }
            );
            state <= RW;
        end
    endrule

    rule do_reset (state == RESET);
        if (ready) begin
            swd_controller.rw.request.put(
                tagged Read { register: Register { apndp: 0, addr: 0 } }
            );
            state <= RW;
        end
    endrule

    rule do_rw (state == RW);
        let response <- swd_controller.rw.response.get();
        case (response) matches
            tagged Write .w_resp: begin
                status <= w_resp.status;
                rdata <= unpack(0);
            end
            tagged Read .r_resp: begin
                Vector#(32, Bit#(1)) resp_rdata;
                resp_rdata = take(unpack(r_resp.rdata));

                if (parity(r_resp.rdata) != 0) begin
                    status <= ERROR;
                    rdata <= unpack(0);
                end
                else begin
                    status <= r_resp.status;
                    rdata <= unpack(pack(resp_rdata));
                end
            end
        endcase
        
        cmd <= tagged Invalid;
        state <= IDLE;
    endrule

    interface ScaffoldBus bus;
        method Action address(a) = bus_address._write(a);
        method Action write_data(w) = bus_write_data._write(w);
        method Action write(b) = bus_write._write(b);
        method Action read(b) = bus_read._write(b);

        method Action en_rdata(en) = bus_en_rdata._write(en);
        method Action en_wdata(en) = bus_en_wdata._write(en);
        method Action en_cmd(en) = bus_en_cmd._write(en);
        method Action en_status(en) = bus_en_status._write(en);

        method Bit#(8) reg_rdata = bus_reg_rdata;
        method Bit#(8) reg_status = bus_reg_status;
    endinterface

    interface SWDControllerPins pins = swd_controller.pins;
endmodule