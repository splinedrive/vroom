//
// RVOOM! Risc-V superscalar O-O
// Copyright (C) 2020-21 Paul Campbell - paul@taniwha.com
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
// 

module fpu(
	input clk,
`ifdef SIMD
    input simd_enable,
`endif

	input reset, 
	input enable,
	input rv32,

	input [CNTRL_SIZE-1:0]control,
	input     [LNCOMMIT-1:0]rd,
	input      [16:12]immed, 
	input	          makes_rd,
	input     [RV-1:0]fr1, fr2, fr3,		// FP ports
	input     [RV-1:0]ir1,				// IP port
	input   [(NHART==1?0:LNHART-1):0]hart,
	input        [2:0]fp_rounding,

	input [NCOMMIT-1:0]commit_kill_0,
	//input [NCOMMIT-1:0]commit_kill_1,

	output [RV-1:0]result,
	output [LNCOMMIT-1:0]res_rd, 
	output			res_makes_fp,			// true if we're writing bask to the FP registers
	output [NHART-1:0]res_makes_rd
	);

    parameter CNTRL_SIZE=7;
	parameter RV=64;
    parameter ADDR=0;
    parameter NHART=1;
    parameter LNHART=0;
    parameter NCOMMIT = 32; // number of commit registers
    parameter LNCOMMIT = 5; // number of bits to encode that
 	parameter RA=5;

	//
	//	rounding mode in immed[14:12]
	//  xtra in immed[15]
	//  xtra2 in immed[16]
	//
	//	ctrl:
	//	5 size	1=D 0=S
	//  4 multiple
	//	3:0 - op 
	//    mult=0
	//		0 = fadd
	//		1 = fsub
	//		2 = fmul
	//		3 = fdiv
	//		4 = fsqrt
	//		5 = fsgn
	//		   mode==0 FSGNJ	
	//		   mode==1 FSGNJN
	//		   mode==2 FSGNJX
	//		6 = fmin/max
	//		   mode==0 FMIN	
	//		   mode==1 FMAX
	//		7 = fcvt/s/d
	//		   xtra2==0 FCVT.d.s
	//		   xtra2==1 FCVT.s.d
	//		8 = fcvt.w.
	//		   xtra==0 fcvt.w.*
	//		   xtra==1 fcvt.*.w
	//		9 = fcvt.wu.
	//		   xtra==0 fcvt.wu.*
	//		   xtra==1 fcvt.*.wu
	//		10 = fcvt.l.
	//		   xtra==0 fcvt.l.*
	//		   xtra==1 fcvt.*.l
	//		11 = fcvt.lu.
	//		   xtra==0 fcvt.lu.*
	//		   xtra==1 fcvt.*.lu
	//		12 = fcmp
	//			mode==0 fle
	//			mode==1 flt
	//			mode==2 feq
	//		13 = fclass
	//		14 = fmv
	//			xtra=0 FMV.X.D
	//			xtra=1 FMV.D.X
	//	   mult==1
	//		0 = fmadd	r1*r2+r3
	//		1 = fmsub	r1*r2-r3
	//		2 = fmnsub	-(r1*r2)+r3
	//		3 = fmnadd	-(r1*r2)-r3
	//
	//	rounding modes:
	//
	//		0 - RNE round to nearest, ties to even
	//		1 - RTZ round towards zero
	//		2 - RDN round downwards
	//		3 - RUP round upwards
	//		4 - RMM round to nearest, ties to max
	//		7 - DYN dynamic

	//
	//	32-bit format			64-bit format
	//
	//		31		- sign			63
	//		30:23	- exponent		62-52
	//			
	//		22:0	- fraction		51-0

	reg [RV-1:0]r_res, c_res;
	assign result = r_res;
	reg  [LNCOMMIT-1:0]r_res_rd, c_res_rd;
	assign res_rd = r_res_rd;
	reg  [NHART-1:0]r_res_makes_rd, c_res_makes_rd;
	assign res_makes_rd = r_res_makes_rd;
	reg	r_makes_rd;
	reg r_res_fp, c_res_fp;
	assign res_makes_fp = r_res_fp;

	wire size = control[5];
	wire multiple = control[4];
	wire [2:0]rounding = (immed[14:12]==3'd7 ? fp_rounding:immed[14:12]);
	wire xtra = immed[15];
	wire xtra2 = immed[16];
	wire [3:0]op = control[3:0];
	reg r_xtra, r_xtra2, r_size, r_multiple;
	reg [3:0]r_op;
	reg [2:0]r_rounding;
	reg   [(NHART==1?0:LNHART-1):0]r_hart;
	reg  [LNCOMMIT-1:0]r_rd;

	reg r_start;
	always @(posedge clk)
		r_start <= enable;
	

	wire [RV-1:0]res_add;
	wire		valid_add;
	wire [LNCOMMIT-1:0]add_rd;
	wire [(NHART==1?0:LNHART-1):0]add_hart;
	fp_add_sub	#(.RV(RV), .LNHART(LNHART), .NHART(NHART), .LNCOMMIT(LNCOMMIT))fpadd(.clk(clk), .reset(reset), 
			.start(r_start && !r_multiple && r_op <= 1),
			.sz(r_size),	// double/single
			.sub(r_op[0]),
			.rd(r_rd),
			.hart(r_hart),
			.rnd(r_rounding),
			.in_1(fr1),
			.in_2(fr2),
			.exception(add_exception),
			.res(res_add),
			.rd_out(add_rd),
			.hart_out(add_hart),
			.valid(valid_add));

	
	wire [RV-1:0]res_mul;
	wire		valid_mul;
	//wire fmuladd = 
	wire [LNCOMMIT-1:0]mul_rd;
	wire [(NHART==1?0:LNHART-1):0]mul_hart;
	fp_mul		#(.RV(RV), .LNHART(LNHART), .NHART(NHART), .LNCOMMIT(LNCOMMIT))fpmul(.clk(clk), .reset(reset),
			.start(r_start && (r_multiple || r_op == 2)),
            .sz(r_size),    // double/single
			.rd(r_rd),
			.hart(r_hart),
			.rnd(r_rounding),
			.in_1(fr1),
			.in_2(fr2),
			.in_3(fr3),
			.fmuladd(fmuladd),  // muladd
			.fmulsub(fmulsub),
			.fmulsign(fmulsign),
			.exception(mul_exception),
			.res(res_mul),
			.rd_out(mul_rd),
			.hart_out(mul_hart),
			.valid(valid_mul));




	always @(posedge clk) begin
		r_xtra <= xtra;
		r_xtra2 <= xtra2;
		r_size <= size;
		r_multiple <= multiple;
		r_op <= op;
		r_hart <= hart;
		r_rounding <= rounding;
		r_rd <= rd;
	end

	reg clk_1;	// 1 clock ops
	always @(*) begin
		c_res_fp = (reset? 0:1);
		clk_1 = 0;
		casez ({valid_mul, valid_add}) // synthesis full_case parallel_case
		2'b1?:	begin
					c_res = res_mul;
					c_res_fp = 1;
				end
		2'b?1:	begin
					c_res = res_add;
					c_res_fp = 1;
				end
		2'b00:
			case (r_op)	// synthesis full_case parallel_case
			3, //		3 = fdiv
			4: //		4 = fsqrt
				c_res = 0;
			5: //		5 = fsgn
				begin
					clk_1 = 1;
					case (r_rounding[1:0]) //synthesis full_case parallel_case
					0:	// fsgnj.q
						c_res = r_size? {fr2[63], fr1[62:0]}         : {fr1[63:32], fr2[31], fr1[30:0]};
					1:	// fsgnjn.q
						c_res = r_size? {~fr2[63], fr1[62:0]}        : {fr1[63:32], ~fr2[31], fr1[30:0]};
					2:	// fsgnjx.q
						c_res = r_size? {fr1[63]^fr2[63], fr1[62:0]} : {fr1[63:32], fr1[31]^fr2[31], fr1[30:0]};
					endcase
				end
			7:	//		7 = fcvt/s/d
				begin
					clk_1 = 1;
					if (r_xtra2) begin //		   xtra2==1 FCVT.s.d  double->single
						if (fr1[62:52] == 11'h7ff) begin
							c_res = {32'hffff_ffff, fr1[63], 8'hff, fr1[51], fr1[21:0]};
						end else begin :cvt
							reg [2:0]guard;
							reg inc, inc_exp;
							reg [7:0]cvt_exp;
							//
							// exp:     3ff -> 7f
							//			371	-> 01	-7e
							//			47e	-> fe   +7e
							cvt_exp = {fr1[62], fr1[58:52]};
							guard = {fr1[28:27], |fr1[26:0]};   // 51:29
							case (r_rounding) //synthesis full_case parallel_case
							0: inc = (guard > 4) || ((guard==4)&&fr1[29]);
							1: inc = 0;
							2: inc = fr1[63] && (guard!=0);
							3: inc = !fr1[63] && (guard!=0);
							4: inc = guard >= 4;
							endcase
							inc_exp = inc && fr1[51:29] == 23'h7fffff;
							
							if ((fr1[62] && fr1[61:59] != 3'b000) || (inc_exp && fr1[62:52] == 11'h47f)) begin	// overflow
								c_res = {32'hffff_ffff, fr1[63], 8'hff, 1'b0, 22'b0}; // inf
							end else 
							if (fr1[62:52] < 11'h367) begin // OK
								c_res = {32'hffff_ffff, fr1[63], 31'b0};
							end else
							if (fr1[62:52] > 11'h380 || (inc_exp && fr1[62:52] == 11'h380)) begin // OK
								if (inc_exp) begin
                                       c_res = {32'hffff_ffff, fr1[63], cvt_exp+8'h1, 23'h0};
                                   end else begin
                                       c_res = {32'hffff_ffff, fr1[63], cvt_exp, fr1[51:29]+{22'b0, inc}};
                                   end
							end else begin : tx		// denorm
								reg [25:0]t;
								reg ainc;
								case (fr1[62:52])  //synthesis full_case parallel_case
								11'h367:	t = {25'b0, 1'b1};
								11'h368:	t = {24'b0, 1'b1, |fr1[51:0]};
`include "mkf4.inc"
								11'h380:	t = {1'b1, fr1[51:28], |fr1[27:0]}; 
								endcase
								case (r_rounding) //synthesis full_case parallel_case
								0: ainc = (t[2:0] > 4) | ((t[2:0]==4)&t[3]);
								1: ainc = 0;
								2: ainc = fr1[63] & (t[2:0]!=0);
								3: ainc = !fr1[63] & (t[2:0]!=0);
								4: ainc = t[2:0]>=4;
								endcase
								c_res = {32'hffff_ffff, fr1[63], 8'h00, t[25:3]+{22'b0,ainc}};
							end
						end
					end else begin	 //		   xtra2==0 FCVT.d.s  single->double
						if (fr1[63:32] != 32'hffff_ffff) begin	// bad
							c_res = {fr1[31], 11'h7ff, 52'h1};
						end else
						if (fr1[30:23] == 8'h00) begin  
							if (fr1[22:0] == 0) begin
								c_res = { fr1[31], 11'b0, 23'b0, 29'b0};
							end else begin	:den // need to un-denorm
								reg [51:0]m;
								reg [10:0]e;
								casez (fr1[22:0]) // synthesis full_case parallel_case
`include "mkf8.inc"
								endcase
								c_res = { fr1[31], e, m};
							end
						end else
						if (fr1[30:23] == 8'hff) begin  
							c_res = { fr1[31], 11'h7ff, fr1[22:0], 29'b0};
						end else begin
							c_res = { fr1[31], fr1[30], {3{~fr1[30]}}, fr1[29:23], fr1[22:0], 29'b0};
						end
					end
				end
			8, //		8 = fcvt.w.*
			9, //      9 = fcvt.wu.*
			10,//      10 = fcvt.l.*
			11://		11 = fcvt.lu.
				if (r_xtra) begin : s8 //		   xtra==1 fcvt.*.wlu
					reg sign;
					reg [63:0]t1, t2;
					reg [54:0]mantissa;
					reg [10:0]exponent;
					clk_1 = 1;
					case (r_op[1:0]) // synthesis full_case parallel_case
					2'b00:	begin	// w
								sign = ir1[31];
								t1 = {{32{ir1[31]}}, ir1[31:0]};
							end
					2'b01:	begin	// wu
								sign = 0;
								t1 = {32'b0, ir1[31:0]};
							end
					2'b10:	begin	// l
								sign = ir1[63];
								t1 = ir1[63:0];
							end
					2'b11:	begin	// lu
								sign = 0;
								t1 = ir1[63:0];
							end
					endcase
					t2 = (sign? ~t1:t1) + {63'b0, sign};
`include "mkf6.inc"
					if (r_size) begin :ffd
						reg [51:0]m3;
						reg [10:0]e3;
						reg inc;

						case (r_rounding) //synthesis full_case parallel_case
						0: inc = (mantissa[2:0]>4) || ((mantissa[2:0]==4) && mantissa[3]);
						1: inc = 0;
						2: inc =  sign && (mantissa[2:0]!=0);
						3: inc = !sign && (mantissa[2:0]!=0);
						4: inc = mantissa[2:0]>=4;
						endcase
						m3 = (inc?mantissa[54:3]+1:mantissa[54:3]);
						e3 = (inc && (mantissa[54:3]==52'hf_ffff_ffff_ffff)?exponent+1:exponent);
						c_res = {sign, e3, m3};
					end else begin : ffs
						reg [22:0]m3;
						reg [7:0]e3;
						reg [2:0]m;
						reg inc;

						m = {mantissa[31:30], |mantissa[29:0]};
						case (r_rounding) //synthesis full_case parallel_case
						0: inc = (m>4) || ((m==4) && mantissa[32]);
						1: inc = 0;
						2: inc =  sign && (m!=0);
						3: inc = !sign && (m!=0);
						4: inc = m >= 4;
						endcase
						m3 = (inc?mantissa[54:32]+1:mantissa[54:32]);
						e3 = (inc && (mantissa[54:32]==(~23'h0))?{exponent[10], exponent[6:0]}+8'b1:{exponent[10], exponent[6:0]});
						c_res = {32'hffff_ffff, sign, e3, m3};
					end
					c_res_fp = 1;
				end else begin :a8 //		   xtra==0 fcvt.wlu.*
					reg [66:0]t;
					reg sign, inc, nan, inf;
					reg zz, o, o2, z;
					reg over, under;
					reg [63:0]tt;
					reg [10:0]e;
					reg [52:0]m;

					clk_1 = 1;
					if (r_size) begin
						sign = fr1[63]&~r_op[0];
						m = {1'b1, fr1[51:0]};
						e = fr1[62:52];
						z = fr1[62:52]==0 && fr1[51:0]==0;
						over = ~fr1[63] && &fr1[62:52];
						under = fr1[63]&r_op[0] || (fr1[63] && &fr1[62:52]);
						nan = fr1[62:52] == ~11'b0 && fr1[50:0] != 51'b00;
						inf = fr1[62:52] == ~11'b0 && fr1[10:0] == 51'b00;
					end else begin
						sign = fr1[31]&~r_op[0];
						m = {1'b1, fr1[22:0], 29'b0};
						e = {fr1[30], {3{~fr1[30]}}, fr1[29:23]};
						z = fr1[30:23]==0 && fr1[22:0]==0;
						over = ~fr1[31] && &fr1[30:23];
						under = fr1[31]&r_op[0] || (fr1[31] && &fr1[30:23]);
						nan = fr1[30:23] == ~8'b0 && fr1[21:0] != 22'b00;
						inf = fr1[30:23] == ~8'b0 && fr1[22:0] == 23'b00;
					end
`include "mkf7.inc"
					case (r_rounding) //synthesis full_case parallel_case
					0: inc = (t[2:0] > 4) | ((t[2:0]==4)&t[3]);
					1: inc = 0;
					2: inc = fr1[63] & (t[2:0]!=0);
					3: inc = !fr1[63] & (t[2:0]!=0);
					4: inc = t[2:0]>=4;
					endcase
					tt = (sign ? ~t[66:3]:t[66:3])+{63'b0, inc^sign};	// convert sign
					// o2 is a prediction of overflow in the above calculation
					casez ({r_op[1:0], sign, inc}) // synthesis full_case parallel_case
					4'b10_00,
					4'b10_11: o2 = t[66]; 
					4'b11_00,
					4'b11_11: o2 = 0; 
					4'b00_00,
					4'b00_11: o2 = |t[65:35] | t[34] | &t[33:3] ; 
					4'b01_00,
					4'b01_11: o2 = |t[66:35]; 
					4'b10_01,
					4'b10_10: o2 = &t[65:3] | t[66];
					4'b11_01,
					4'b11_10: o2 = &t[66:3];
					4'b00_01,
					4'b00_10: o2 = |t[66:35] | &t[33:3] | t[34];
					4'b01_01,
					4'b01_10: o2 = |t[66:35] | &t[34:3];
					endcase
					casez ({r_op[0], under|((o|o2)&sign)|(inf&sign), over|((o|o2|inf)&~sign)|nan, zz|z, r_op[1]}) // synthesis full_case parallel_case
					5'b?_000_?: c_res = tt;
					5'b0_1??_1: c_res = {1'b1, 63'b0};
					5'b0_1??_0: c_res = {~33'b0, 31'b0};
					5'b1_1??_?: c_res = 64'b0;
					5'b0_?1?_1: c_res = {1'b0, ~63'b0};
					5'b0_?1?_0: c_res = {33'b0, ~31'b0};
					5'b1_?1?_1: c_res = ~64'b0;
					5'b1_?1?_0: c_res = {32'b0,~32'b0};
					5'b?_??1_?: c_res = 64'b0;
					endcase
					c_res_fp = 0;
				end
			6,	//		6  = fmin/fmax
			12: //		12 = fcmp
				begin : cmp
					reg nan_a, nan_b, inf_a, inf_b, sign_a, sign_b;
					reg snan_a, snan_b;
					reg [10:0]exp_a, exp_b;
					reg [51:0]man_a, man_b;
					reg v;
					reg lt; 

					clk_1 = 1;
					nan_a = (r_size? (fr1[62:52] == 11'h7ff && fr1[51:0] != 52'b0) :
								   (fr1[63:32] != 32'hffff_ffff) ||
									(fr1[30:23] == 8'hff && fr1[22:0] != 23'b0));
					snan_a = (r_size? fr1[51] : fr1[22]);
					nan_b = (r_size? (fr2[62:52] == 11'h7ff && fr2[51:0] != 52'b0) :
								   (fr2[63:32] != 32'hffff_ffff) ||
									(fr2[30:23] == 8'hff && fr2[22:0] != 23'b0));
					snan_b = (r_size? fr2[51] : fr2[22]);
					inf_a = (r_size? (fr1[62:52] == 11'h7ff && fr1[51:0] == 52'b0) :
								   (fr1[30:23] == 8'hff && fr1[22:0] == 23'b0));
					inf_b = (r_size? (fr2[62:52] == 11'h7ff && fr2[51:0] == 52'b0) :
								   (fr2[30:23] == 8'hff && fr2[22:0] == 23'b0));
					sign_a = (r_size ? fr1[63] : fr1[31]);
					sign_b = (r_size ? fr2[63] : fr2[31]);
					exp_a = (r_size? fr1[62:52] : {fr1[30], {3{~fr1[30]}}, fr1[29:23]});
					exp_b = (r_size? fr2[62:52] : {fr2[30], {3{~fr2[30]}}, fr2[29:23]});
					man_a = (r_size ? fr1[51:0] : {fr1[22:0], 29'b0});
					man_b = (r_size ? fr2[51:0] : {fr2[22:0], 29'b0});

					if (nan_a || nan_b ) begin
						v = 0;
						lt = 1'bx;
					end else begin
						reg eq;

						if (sign_a != sign_b) begin
							lt = sign_a;
							eq = 0;
						end else
						if (inf_a || inf_b) begin
							if (inf_a && inf_b) begin
								eq = 1;
								lt = 0;
							end else begin
								eq = 0;
								lt = !(inf_a^sign_a);
							end
						end else
						if (exp_a != exp_b) begin
							eq = 0;
							lt = (exp_a < exp_b)^sign_a;
						end else 
						if (man_a != man_b) begin
							eq = 0;
							lt = (man_a < man_b)^sign_a;
						end else begin
							eq = 1;
							lt = 0;
						end
						case (r_rounding[1:0]) //synthesis full_case parallel_case
						0: v = eq || lt; // fle
						1: v = lt;		 // flt
						2: v = eq;       // feq
						endcase
					end
					if (!r_op[3]) begin
						if (nan_a || nan_b ) begin
							if (nan_a && !snan_a && !nan_b) begin
								c_res = fr2;
							end else
							if (!nan_a && nan_b && !snan_b) begin
								c_res = fr1;
							end else begin
								if (r_size) begin
									c_res = 64'h7FF0_0000_0000_0000;
								end else begin
									c_res = 64'hffff_ffff_7F80_0000;
								end
							end
						end else begin
							c_res = (lt^r_rounding[0] ? fr1:fr2); // r_rounding[0] is fmin/fmax
						end
						c_res_fp = 1;
					end else begin
						c_res = {63'b0, v};
						c_res_fp = 0;
					end
				end
			13:	//		13 = fclass
				begin
					clk_1 = 1;
					if (r_size) begin
						c_res = {54'b0,
							/*9 +qnan*/	(fr1[62:52] == 11'h7ff) & fr1[51],
							/*8 +snan*/	(fr1[62:52] == 11'h7ff) & ~fr1[51] & (fr1[50:0] != 52'b00),
							/*7 +inf */	~fr1[63] & (fr1[62:52] == 11'h7ff) & (fr1[51:0] == 52'b0),
							/*6 +    */	~fr1[63] & (fr1[62:52] != 11'h7ff) & (fr1[62:52] != 11'h0),
							/*5 +sub */	~fr1[63] & (fr1[62:52] == 11'h0) & (fr1[51:0] != 0),
							/*4 +0   */	~fr1[63] & (fr1[62:0] == 63'h0),
							/*3 -0   */	fr1[63] & (fr1[62:0] == 63'h0),
							/*2 -sub */	fr1[63] & (fr1[62:52] == 11'h0) & (fr1[51:0] != 0),
							/*1 -    */	fr1[63] & (fr1[62:52] != 11'h7ff) & (fr1[62:52] != 11'h0),
							/*0 -inf */	fr1[63] & (fr1[62:52] == 11'h7ff) & (fr1[51:0] == 51'b0)
							};
					end else begin
						c_res = {54'b0,
							/*9*/	(fr1[30:23] == 8'hff) &  fr1[22] & (fr1[21:0] != 22'b00) | (fr1[63:32]!=32'hffff_ffff),
							/*8*/	(fr1[30:23] == 8'hff) & ~fr1[22] & (fr1[21:0] != 22'b00) & (fr1[63:32]==32'hffff_ffff),
							/*7*/	~fr1[31] & (fr1[30:23] == 8'hff) & (fr1[22:0] == 23'b0) & (fr1[63:32]==32'hffff_ffff),
							/*6*/	~fr1[31] & (fr1[30:23] != 8'hff) & (fr1[30:23] != 8'h0) & (fr1[63:32]==32'hffff_ffff),
							/*5*/	~fr1[31] & (fr1[30:23] == 8'h0) & (fr1[63:32]==32'hffff_ffff) & (fr1[22:0] != 0),
							/*4*/	~fr1[31] & (fr1[30:0] == 31'h0) & (fr1[63:32]==32'hffff_ffff),
							/*3*/	fr1[31] & (fr1[30:0] == 31'h0) & (fr1[63:32]==32'hffff_ffff),
							/*2*/	fr1[31] & (fr1[30:23] == 8'h0) & (fr1[63:32]==32'hffff_ffff) & (fr1[22:0] != 0),
							/*1*/	fr1[31] & (fr1[30:23] != 8'hff) & (fr1[30:23] != 8'h0) & (fr1[63:32]==32'hffff_ffff),
							/*0*/	fr1[31] & (fr1[30:23] == 8'hff) & (fr1[22:0] == 23'b0) & (fr1[63:32]==32'hffff_ffff)
								};
					end
					c_res_fp = 0;
				end
			14: //		14 = fmv
				if (r_xtra) begin	// FMV.D.X
					clk_1 = 1;
					if (r_size) begin
						c_res = ir1;
					end else begin
						c_res = {32'hffff_ffff, ir1[31:0]};
					end
				end else begin				// FMV.X.D
					clk_1 = 1;
					if (r_size) begin
						c_res = fr1;
					end else begin
						c_res = {{32{fr1[31]}}, fr1[31:0]};
					end
					c_res_fp = 0;
				end
			default: begin c_res_fp = 'bx; c_res = 'bx; end
			endcase
		endcase
		c_res_makes_rd = 0;
		casez ({valid_add, valid_mul}) // synthesis full_case parallel_case
		2'b1?: begin
					c_res_makes_rd[add_hart] = 1;
					c_res_rd = add_rd;
			   end
		2'b?1: begin
					c_res_makes_rd[mul_hart] = 1;
					c_res_rd = mul_rd;
			   end
		2'b00: begin
					c_res_makes_rd[r_hart] = clk_1&r_start;
					c_res_rd = r_rd;
			   end
		endcase
	end

	always @(posedge clk) begin
        r_res_makes_rd <= c_res_makes_rd;
		r_res_rd <= c_res_rd;
		r_res_fp <= c_res_fp;
		r_res <= c_res;
`ifdef SIMD
        if (|c_res_makes_rd && simd_enable) $display("F %d @ %x <- %x",$time,c_res_rd,c_res);
`endif

	end

endmodule

/* For Emacs:
 * Local Variables:
 * mode:c
 * indent-tabs-mode:t
 * tab-width:4
 * c-basic-offset:4
 * End:
 * For VIM:
 * vim:set softtabstop=4 shiftwidth=4 tabstop=4:
 */


