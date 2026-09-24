// 32-bit adder with carry in/out. Parameterizable width.
// Verilog-2005, synthesizable, single continuous assignment.
module adder32 #(
    parameter WIDTH = 32
) (
    input  [WIDTH - 1 : 0] a,
    input  [WIDTH - 1 : 0] b,
    input                cin,
    output [WIDTH - 1 : 0] sum,
    output             cout
);
    assign {cout, sum} = a + b + cin;
endmodule
