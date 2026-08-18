// Simple smoke-test testbench for adder32: fixed vectors, checks env works.
module tb_adder32;

    localparam WIDTH = 32;
    reg  [WIDTH-1:0] a, b;
    reg              cin;
    wire [WIDTH-1:0] sum;
    wire             cout;

    integer errors = 0;

    adder32 #(.WIDTH(WIDTH)) dut (
        .a   (a),
        .b   (b),
        .cin (cin),
        .sum (sum),
        .cout(cout)
    );

    task check;
        input [WIDTH-1:0] ea;
        input [WIDTH-1:0] eb;
        input             ecin;
        input [WIDTH-1:0] esum;
        input             ecout;
        begin
            a = ea; b = eb; cin = ecin;
            #1;
            if (sum !== esum || cout !== ecout) begin
                $display("FAIL: %h + %h + %b = %h (cout %b), expect %h (cout %b)",
                         a, b, cin, sum, cout, esum, ecout);
                errors = errors + 1;
            end else
                $display("PASS: %h + %h + %b = %h (cout %b)", a, b, cin, sum, cout);
        end
    endtask

    initial begin
        $dumpfile("sim/exec/tb_adder32.vcd");
        $dumpvars(0, tb_adder32);

        check(32'd0,         32'd0,         1'b0, 32'd0,          1'b0);
        check(32'd123456789, 32'd987654321, 1'b0, 32'd1111111110, 1'b0);
        check(32'hFFFFFFFF,  32'd1,         1'b0, 32'd0,          1'b1);
        check(32'hFFFFFFFF,  32'hFFFFFFFF,  1'b0, 32'hFFFFFFFE,   1'b1);
        check(32'd42,        32'd58,        1'b1, 32'd101,        1'b0);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else begin
            $display("%0d TESTS FAILED", errors);
            $stop; // vvp -N: 失败退出码为 1
        end
        $finish;
    end

endmodule
