-- Copyright(c) 2024 by Tsuyoshi Hamada
--
-- 32ビットの単精度浮動小数点数を加算し、IEEE 754標準の丸め処理（ガードビット[G]、ラウンドビット[R]、スティッキービット[S]を使用）を適用したバージョン
--   (*) つまりGRSはGuard, Round, Stickeyに由来します。
--
-- 主要な変更点
--
-- ガードビット、ラウンドビット、スティッキービットの追加:
-- 仮数を処理する際に、仮数部分を拡張してG、R、Sビットを含めました。
-- 仮数のビット幅を FRAC_WIDTH + 4 に拡張しました（元の仮数ビット + GRSビット）。
-- 
-- 指数の比較とシフト量の計算:
-- larger_exp を使用して、大きい方の指数を決定しました。
-- shift_amount を計算し、仮数を適切なビット数だけ右シフトします。
-- 
-- 仮数のアラインメント:
-- 指数差に基づいて、仮数を右にシフトしてアラインメントを行います。
-- シフト時にスティッキービットを計算するため、仮数を拡張しています。
-- 
-- 加算・減算操作:
-- 符号に基づいて、仮数の加算または減算を行います。
-- 符号が異なる場合、大きい方から小さい方を減算し、結果の符号を設定します。
-- 
-- 丸め処理の実装:
-- ガードビット（G）、ラウンドビット（R）、スティッキービット（S）を使用して、IEEE 754標準の最近接偶数への丸めを行います。
-- 丸め条件に基づいて、仮数に1を加算するかを決定します。
-- 
-- 正規化の処理:
-- 仮数に繰り上がりが発生した場合、指数をインクリメントします。
-- 先頭のビットがゼロの場合、左にシフトして正規化し、指数をデクリメントします。
-- 重要なポイント
-- 
-- スティッキービットの計算:
-- シフト操作の際、シフトアウトされたビットが1であれば、スティッキービットを1に設定します。
-- スティッキービットは、シフトアウトされたすべてのビットの論理和です。
-- 
-- 丸めの条件:
-- IEEE 754標準の最近接偶数への丸め（Round to Nearest Even）を実装しています。
-- ガードビット、ラウンドビット、スティッキービットの組み合わせに基づいて、丸めるかどうかを判断します。
-- 
-- 指数部の範囲:
-- 指数部を integer 型で扱い、範囲を明確にしました。
-- 
-- 符号の決定:
-- 符号が異なる場合の減算後、結果の符号を適切に設定しています。
-- 
-- 注意点
-- 
-- 正規化処理のループ:
-- while ループを使用していますが、これは合成ツールによってはサポートされない場合があります。
-- 合成可能なコードにするためには、先頭の1を検出するロジックを組み合わせ回路で実装する必要があります。
-- 
-- オーバーフローとアンダーフロー:
-- 指数が最大値または最小値を超える場合の処理は追加で実装する必要があります。
-- 特殊な値の処理:
-- 
-- NaN、Infinity、ゼロなどの特殊な浮動小数点数の処理は、このコードには含まれていません。
-- 

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fp32add_pipe_round is
    Port (
        clk     : in  std_logic;                -- クロック信号
        rst     : in  std_logic;                -- リセット信号
        a       : in  std_logic_vector(31 downto 0); -- 32ビット入力 a
        b       : in  std_logic_vector(31 downto 0); -- 32ビット入力 b
        result  : out std_logic_vector(31 downto 0)  -- 32ビット結果
    );
end fp32add_pipe_round;

architecture rtl of fp32add_pipe_round is
    -- 定数の定義
    constant EXP_WIDTH : integer := 8;
    constant FRAC_WIDTH : integer := 23;
    constant TOTAL_WIDTH : integer := 32;
    constant BIAS : std_logic_vector(EXP_WIDTH - 1 downto 0) := "01111111"; -- 127をバイナリで表現

    -- パイプラインレジスタ
    signal reg_stage1_sign_a, reg_stage1_sign_b: std_logic;
    signal reg_stage1_exp_a, reg_stage1_exp_b: std_logic_vector(EXP_WIDTH - 1 downto 0);
    signal reg_stage1_frac_a, reg_stage1_frac_b: std_logic_vector(FRAC_WIDTH downto 0); -- 隠れビットを含む
    signal reg_stage1_exp_diff : integer range -255 to 255;

    signal reg_stage2_sign_res: std_logic;
    signal reg_stage2_exp_res: integer range 0 to 255;
    signal reg_stage2_frac_res: std_logic_vector(FRAC_WIDTH + 4 downto 0); -- 仮数部 + GRSビット

    -- その他の信号
    signal aligned_frac_a, aligned_frac_b : std_logic_vector(FRAC_WIDTH + 4 downto 0); -- アラインメント後の仮数（GRSビットを含む）
    signal sum_frac : std_logic_vector(FRAC_WIDTH + 4 downto 0); -- 和の結果（GRSビットを含む）
    signal shift_amount : integer range 0 to 255;
    signal larger_exp : integer range 0 to 255;
    signal sticky_bit : std_logic;

    -- 最終出力レジスタ
    signal reg_result : std_logic_vector(31 downto 0);

begin
    -- クロック同期レジスタ
    process (clk, rst)
    begin
        if rst = '1' then
            -- レジスタの初期化
            reg_stage1_sign_a <= '0';
            reg_stage1_sign_b <= '0';
            reg_stage1_exp_a <= (others => '0');
            reg_stage1_exp_b <= (others => '0');
            reg_stage1_frac_a <= (others => '0');
            reg_stage1_frac_b <= (others => '0');
            reg_stage1_exp_diff <= 0;

            reg_stage2_sign_res <= '0';
            reg_stage2_exp_res <= 0;
            reg_stage2_frac_res <= (others => '0');

            reg_result <= (others => '0');
        elsif rising_edge(clk) then
            -- パイプラインステージ1のレジスタ更新
            reg_stage1_sign_a <= a(31);
            reg_stage1_sign_b <= b(31);
            reg_stage1_exp_a <= a(30 downto 23);
            reg_stage1_exp_b <= b(30 downto 23);
            reg_stage1_frac_a <= '1' & a(22 downto 0); -- 隠れビットを追加
            reg_stage1_frac_b <= '1' & b(22 downto 0); -- 隠れビットを追加
            reg_stage1_exp_diff <= to_integer(signed(('0' & reg_stage1_exp_a)) - signed(('0' & reg_stage1_exp_b)));

            -- パイプラインステージ2のレジスタ更新
            reg_stage2_sign_res <= reg_stage1_sign_a;
            reg_stage2_exp_res <= larger_exp;
            reg_stage2_frac_res <= sum_frac;

            -- 正規化処理
            if reg_stage2_frac_res(FRAC_WIDTH + 4) = '1' then
                -- 繰り上がり発生
                reg_stage2_exp_res <= reg_stage2_exp_res + 1;
                reg_stage2_frac_res <= '0' & reg_stage2_frac_res(FRAC_WIDTH + 4 downto 1);
            else
                -- 先頭の1を探す
                while reg_stage2_frac_res(FRAC_WIDTH + 3) = '0' and reg_stage2_exp_res > 0 loop
                    reg_stage2_frac_res <= reg_stage2_frac_res(FRAC_WIDTH + 3 downto 0) & '0';
                    reg_stage2_exp_res <= reg_stage2_exp_res - 1;
                end loop;
            end if;

            -- 丸め処理を適用
            if reg_stage2_frac_res(FRAC_WIDTH + 1) = '1' then
                if (reg_stage2_frac_res(FRAC_WIDTH) = '1') or (sticky_bit = '1') then
                    -- 仮数に1を加算
                    reg_stage2_frac_res(FRAC_WIDTH + 4 downto FRAC_WIDTH + 2) <= std_logic_vector(unsigned(reg_stage2_frac_res(FRAC_WIDTH + 4 downto FRAC_WIDTH + 2)) + 1);
                end if;
            end if;

            -- 最終結果の格納
            reg_result <= reg_stage2_sign_res & std_logic_vector(to_unsigned(reg_stage2_exp_res, EXP_WIDTH)) & reg_stage2_frac_res(FRAC_WIDTH downto 1);
        end if;
    end process;

    -- 組み合わせ回路：指数の比較とアラインメント
    larger_exp <= integer'max(to_integer(unsigned(reg_stage1_exp_a)), to_integer(unsigned(reg_stage1_exp_b)));
    shift_amount <= abs(reg_stage1_exp_diff);

    process (reg_stage1_frac_a, reg_stage1_frac_b, reg_stage1_exp_diff, shift_amount)
        variable temp_frac_b : std_logic_vector(FRAC_WIDTH + 4 downto 0);
        variable shifted_out_bits : std_logic_vector(shift_amount - 1 downto 0);
    begin
        if reg_stage1_exp_diff >= 0 then
            -- 'a' の指数が大きい場合、'b' の仮数をシフト
            aligned_frac_a <= reg_stage1_frac_a & "0000"; -- GRSビットのために4ビット拡張
            temp_frac_b := reg_stage1_frac_b & "0000"; -- 一時的な変数に格納
            if shift_amount < FRAC_WIDTH + 5 then
                aligned_frac_b <= ('0' & temp_frac_b) srl shift_amount;
                shifted_out_bits := temp_frac_b(shift_amount - 1 downto 0);
            else
                aligned_frac_b <= (others => '0');
                shifted_out_bits := temp_frac_b(FRAC_WIDTH + 4 downto 0);
            end if;
        else
            -- 'b' の指数が大きい場合、'a' の仮数をシフト
            aligned_frac_b <= reg_stage1_frac_b & "0000"; -- GRSビットのために4ビット拡張
            temp_frac_b := reg_stage1_frac_a & "0000"; -- 一時的な変数に格納
            if shift_amount < FRAC_WIDTH + 5 then
                aligned_frac_a <= ('0' & temp_frac_b) srl shift_amount;
                shifted_out_bits := temp_frac_b(shift_amount - 1 downto 0);
            else
                aligned_frac_a <= (others => '0');
                shifted_out_bits := temp_frac_b(FRAC_WIDTH + 4 downto 0);
            end if;
        end if;

        -- スティッキービットの計算
        if shifted_out_bits'length > 0 then
            sticky_bit <= or_reduce(shifted_out_bits);
        else
            sticky_bit <= '0';
        end if;
    end process;

    -- 組み合わせ回路：加算・減算操作
    process (aligned_frac_a, aligned_frac_b, reg_stage1_sign_a, reg_stage1_sign_b)
    begin
        if reg_stage1_sign_a = reg_stage1_sign_b then
            -- 符号が同じ場合は加算
            sum_frac <= std_logic_vector(unsigned(aligned_frac_a) + unsigned(aligned_frac_b));
            reg_stage2_sign_res <= reg_stage1_sign_a;
        else
            -- 符号が異なる場合は減算
            if unsigned(aligned_frac_a) >= unsigned(aligned_frac_b) then
                sum_frac <= std_logic_vector(unsigned(aligned_frac_a) - unsigned(aligned_frac_b));
                reg_stage2_sign_res <= reg_stage1_sign_a;
            else
                sum_frac <= std_logic_vector(unsigned(aligned_frac_b) - unsigned(aligned_frac_a));
                reg_stage2_sign_res <= reg_stage1_sign_b;
            end if;
        end if;
    end process;

    -- 出力
    result <= reg_result;
end rtl;
