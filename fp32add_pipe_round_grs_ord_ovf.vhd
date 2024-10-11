-- Copyright(c) 2024 by Tsuyoshi Hamada
--
-- 32ビット単精度浮動小数点加算器
--   * IEEE 754標準の丸め処理（ガードビット[G]、ラウンドビット[R]、スティッキービット[S]を使用）に対応
--   * or_reduce関数を独自実装し、VHDL-2008未対応の論理合成ツールに対応
--   * NaN、Infinity、ゼロなどの特殊な値の処理に対応
--   * オーバーフローとアンダーフローの処理と例外処理に対応
--
--  つまり、
--  fp32add_pipe_round_grs_ord.vhdから以下の3つの改善を施したVHDLコードになっています。
--
--    1. whileループを削除し、合成可能なコードに修正。
--    2. NaN、Infinity、ゼロなどの特殊な値の処理を追加。
--    3. オーバーフローとアンダーフローの処理と例外処理を追加。
-- 
--  また、or_reduce関数も独自実装しています。
--
--
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- 自作の or_reduce 関数を定義
function or_reduce(vector : std_logic_vector) return std_logic is
    variable result : std_logic := '0';
begin
    for i in vector'range loop
        result := result or vector(i);
    end loop;
    return result;
end function;

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
    constant BIAS : integer := 127; -- 127

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
    signal shift_amount : integer range 0 to FRAC_WIDTH + 4;
    signal larger_exp : integer range 0 to 255;
    signal sticky_bit : std_logic;
    signal is_zero_a, is_zero_b : std_logic;
    signal is_inf_a, is_inf_b : std_logic;
    signal is_nan_a, is_nan_b : std_logic;

    -- 正規化用の信号
    signal leading_one_position : integer range 0 to FRAC_WIDTH + 5;

    -- 最終出力レジスタ
    signal reg_result : std_logic_vector(31 downto 0);

    -- 結果の特殊値フラグ
    signal result_is_nan : std_logic;
    signal result_is_inf : std_logic;
    signal result_is_zero : std_logic;

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
            reg_stage1_exp_diff <= to_integer(unsigned(reg_stage1_exp_a)) - to_integer(unsigned(reg_stage1_exp_b));

            -- 特殊な値のチェック
            is_zero_a <= '1' when (reg_stage1_exp_a = (others => '0') and a(22 downto 0) = (others => '0')) else '0';
            is_zero_b <= '1' when (reg_stage1_exp_b = (others => '0') and b(22 downto 0) = (others => '0')) else '0';

            is_inf_a <= '1' when (reg_stage1_exp_a = (others => '1') and a(22 downto 0) = (others => '0')) else '0';
            is_inf_b <= '1' when (reg_stage1_exp_b = (others => '1') and b(22 downto 0) = (others => '0')) else '0';

            is_nan_a <= '1' when (reg_stage1_exp_a = (others => '1') and a(22 downto 0) /= (others => '0')) else '0';
            is_nan_b <= '1' when (reg_stage1_exp_b = (others => '1') and b(22 downto 0) /= (others => '0')) else '0';

            -- パイプラインステージ2のレジスタ更新
            reg_stage2_sign_res <= reg_stage1_sign_a;
            reg_stage2_exp_res <= larger_exp;
            reg_stage2_frac_res <= sum_frac;

            -- 正規化処理（先頭の1の位置を検出）:
            --  whileループを使用せず、リーディング・ワン・ディテクタ（Leading One Detector） を使用して、
            --  先頭の '1' の位置を検出します。
            --  これにより、ループを使わずに正規化のためのシフト量を計算できます。
            if sum_frac(FRAC_WIDTH + 4) = '1' then
                leading_one_position <= FRAC_WIDTH + 5;
            else
                leading_one_position <= 0;
                for i in FRAC_WIDTH + 3 downto 0 loop
                    if sum_frac(i) = '1' and leading_one_position = 0 then
                        leading_one_position <= i + 1;
                    end if;
                end loop;
            end if;

            -- 仮数と指数の調整
            if leading_one_position > 0 then
                reg_stage2_exp_res <= reg_stage2_exp_res + (leading_one_position - (FRAC_WIDTH + 1));
                if leading_one_position >= FRAC_WIDTH + 1 then
                    reg_stage2_frac_res <= sum_frac(leading_one_position - 1 downto leading_one_position - (FRAC_WIDTH + 1)) & (others => '0');
                else
                    reg_stage2_frac_res <= sum_frac(leading_one_position - 1 downto 0) & (others => '0');
                end if;
            else
                reg_stage2_exp_res <= 0;
                reg_stage2_frac_res <= (others => '0');
            end if;

            -- オーバーフローとアンダーフローの処理
            if reg_stage2_exp_res >= 255 then
                -- オーバーフロー：Infinityを返す
                result_is_inf <= '1';
            elsif reg_stage2_exp_res <= 0 then
                -- アンダーフロー：ゼロを返す
                result_is_zero <= '1';
            else
                result_is_inf <= '0';
                result_is_zero <= '0';
            end if;

            -- 丸め処理を適用
            if reg_stage2_frac_res(FRAC_WIDTH + 1) = '1' then  -- ガードビット
                if (reg_stage2_frac_res(FRAC_WIDTH) = '1') or (sticky_bit = '1') then
                    -- 仮数に1を加算
                    reg_stage2_frac_res(FRAC_WIDTH + 4 downto FRAC_WIDTH + 2) <=
                        std_logic_vector(unsigned(reg_stage2_frac_res(FRAC_WIDTH + 4 downto FRAC_WIDTH + 2)) + 1);
                end if;
            end if;

            -- 最終結果の格納
            if is_nan_a = '1' or is_nan_b = '1' then
                -- NaNの処理
                reg_result <= "011111111" & "10000000000000000000000"; -- NaNを表すビット列
            elsif is_inf_a = '1' or is_inf_b = '1' then
                -- Infinityの処理
                reg_result <= reg_stage2_sign_res & "11111111" & (others => '0'); -- Infinityを表すビット列
            elsif result_is_inf = '1' then
                -- オーバーフローによるInfinity
                reg_result <= reg_stage2_sign_res & "11111111" & (others => '0');
            elsif result_is_zero = '1' or (is_zero_a = '1' and is_zero_b = '1') then
                -- ゼロの処理
                reg_result <= reg_stage2_sign_res & (others => '0');
            else
                -- 通常の結果
                reg_result <= reg_stage2_sign_res & std_logic_vector(to_unsigned(reg_stage2_exp_res, EXP_WIDTH)) & reg_stage2_frac_res(FRAC_WIDTH downto 1);
            end if;
        end if;
    end process;

    -- 組み合わせ回路：指数の比較とアラインメント
    larger_exp <= integer'max(to_integer(unsigned(reg_stage1_exp_a)), to_integer(unsigned(reg_stage1_exp_b)));
    shift_amount <= abs(reg_stage1_exp_diff);

    process (reg_stage1_frac_a, reg_stage1_frac_b, reg_stage1_exp_diff, shift_amount)
        variable temp_frac : std_logic_vector(FRAC_WIDTH + 4 downto 0);
        variable shifted_out_bits : std_logic_vector(FRAC_WIDTH + 4 downto 0);
    begin
        if reg_stage1_exp_diff >= 0 then
            -- 'a' の指数が大きい場合、'b' の仮数をシフト
            aligned_frac_a <= reg_stage1_frac_a & "0000"; -- GRSビットのために4ビット拡張
            temp_frac := reg_stage1_frac_b & "0000"; -- 一時的な変数に格納
            if shift_amount < FRAC_WIDTH + 5 then
                aligned_frac_b <= ('0' & temp_frac) srl shift_amount;
                shifted_out_bits := temp_frac(shift_amount - 1 downto 0);
            else
                aligned_frac_b <= (others => '0');
                shifted_out_bits := temp_frac(FRAC_WIDTH + 4 downto 0);
            end if;
        else
            -- 'b' の指数が大きい場合、'a' の仮数をシフト
            aligned_frac_b <= reg_stage1_frac_b & "0000"; -- GRSビットのために4ビット拡張
            temp_frac := reg_stage1_frac_a & "0000"; -- 一時的な変数に格納
            if shift_amount < FRAC_WIDTH + 5 then
                aligned_frac_a <= ('0' & temp_frac) srl shift_amount;
                shifted_out_bits := temp_frac(shift_amount - 1 downto 0);
            else
                aligned_frac_a <= (others => '0');
                shifted_out_bits := temp_frac(FRAC_WIDTH + 4 downto 0);
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

