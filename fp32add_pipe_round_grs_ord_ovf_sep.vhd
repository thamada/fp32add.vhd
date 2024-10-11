-- Copyright(c) 2024 by Tsuyoshi Hamada
--
-- -------------------------------------------
-- IEEE-754形式32ビット単精度浮動小数点加算器
-- -------------------------------------------
--
--   * IEEE 754標準の丸め処理（ガードビット[G]、ラウンドビット[R]、スティッキービット[S]を使用）に対応
--   * or_reduce関数を独自実装し、VHDL-2008未対応の論理合成ツールに対応
--   * NaN、Infinity、ゼロなどの特殊な値の処理に対応
--   * オーバーフローとアンダーフローの処理と例外処理に対応
--   * 正規化処理にリーディング・ワン・ディテクタ(Leading One Detector)を使い多くの合成ツールに対応
--   * 組み合わせ回路とパイプラインレジスタを明確に区別した読みやすいRTL記述
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
    -- ステージ1レジスタ
    signal reg_stage1_sign_a, reg_stage1_sign_b: std_logic;
    signal reg_stage1_exp_a, reg_stage1_exp_b: std_logic_vector(EXP_WIDTH - 1 downto 0);
    signal reg_stage1_frac_a, reg_stage1_frac_b: std_logic_vector(FRAC_WIDTH downto 0); -- 隠れビットを含む
    signal reg_stage1_exp_diff : integer range -255 to 255;

    -- ステージ2レジスタ
    signal reg_stage2_sign_res: std_logic;
    signal reg_stage2_exp_res: integer range 0 to 255;
    signal reg_stage2_frac_res: std_logic_vector(FRAC_WIDTH + 4 downto 0); -- 仮数部 + GRSビット

    -- 最終結果レジスタ
    signal reg_result : std_logic_vector(31 downto 0);

    -- 組み合わせ回路用の信号
    -- ステージ1の組み合わせ回路
    signal stage1_sign_a, stage1_sign_b: std_logic;
    signal stage1_exp_a, stage1_exp_b: std_logic_vector(EXP_WIDTH - 1 downto 0);
    signal stage1_frac_a, stage1_frac_b: std_logic_vector(FRAC_WIDTH downto 0);
    signal exp_diff : integer range -255 to 255;

    -- 特殊な値のフラグ
    signal is_zero_a, is_zero_b : std_logic;
    signal is_inf_a, is_inf_b : std_logic;
    signal is_nan_a, is_nan_b : std_logic;

    -- アラインメントとシフト用の信号
    signal larger_exp : integer range 0 to 255;
    signal shift_amount : integer range 0 to FRAC_WIDTH + 4;
    signal aligned_frac_a, aligned_frac_b : std_logic_vector(FRAC_WIDTH + 4 downto 0);
    signal shifted_out_bits : std_logic_vector(FRAC_WIDTH + 4 downto 0);
    signal sticky_bit : std_logic;

    -- 加算・減算結果
    signal sum_frac : std_logic_vector(FRAC_WIDTH + 4 downto 0);
    signal stage2_sign_res : std_logic;

    -- 正規化用の信号
    signal leading_one_position : integer range 0 to FRAC_WIDTH + 5;
    signal normalized_frac : std_logic_vector(FRAC_WIDTH + 4 downto 0);
    signal normalized_exp : integer range 0 to 255;

    -- オーバーフローとアンダーフローのフラグ
    signal result_is_inf : std_logic;
    signal result_is_zero : std_logic;

    -- 最終結果
    signal final_result : std_logic_vector(31 downto 0);

begin
    -- ステージ1の組み合わせ回路
    stage1_sign_a <= a(31);
    stage1_sign_b <= b(31);
    stage1_exp_a <= a(30 downto 23);
    stage1_exp_b <= b(30 downto 23);
    stage1_frac_a <= '1' & a(22 downto 0); -- 隠れビットを追加
    stage1_frac_b <= '1' & b(22 downto 0); -- 隠れビットを追加

    exp_diff <= to_integer(unsigned(stage1_exp_a)) - to_integer(unsigned(stage1_exp_b));

    -- 特殊な値のチェック
    is_zero_a <= '1' when (stage1_exp_a = (others => '0') and a(22 downto 0) = (others => '0')) else '0';
    is_zero_b <= '1' when (stage1_exp_b = (others => '0') and b(22 downto 0) = (others => '0')) else '0';

    is_inf_a <= '1' when (stage1_exp_a = (others => '1') and a(22 downto 0) = (others => '0')) else '0';
    is_inf_b <= '1' when (stage1_exp_b = (others => '1') and b(22 downto 0) = (others => '0')) else '0';

    is_nan_a <= '1' when (stage1_exp_a = (others => '1') and a(22 downto 0) /= (others => '0')) else '0';
    is_nan_b <= '1' when (stage1_exp_b = (others => '1') and b(22 downto 0) /= (others => '0')) else '0';

    -- アラインメントとシフト
    larger_exp <= integer'max(to_integer(unsigned(stage1_exp_a)), to_integer(unsigned(stage1_exp_b)));
    shift_amount <= abs(exp_diff);

    -- アラインメントとスティッキービットの計算
    process(stage1_frac_a, stage1_frac_b, exp_diff, shift_amount)
        variable temp_frac : std_logic_vector(FRAC_WIDTH + 4 downto 0);
        variable temp_shifted_bits : std_logic_vector(FRAC_WIDTH + 4 downto 0);
    begin
        if exp_diff >= 0 then
            -- 'a' の指数が大きい場合、'b' の仮数をシフト
            aligned_frac_a <= stage1_frac_a & "0000"; -- GRSビットのために4ビット拡張
            temp_frac := stage1_frac_b & "0000"; -- 一時的な変数に格納
            if shift_amount < FRAC_WIDTH + 5 then
                aligned_frac_b <= ('0' & temp_frac) srl shift_amount;
                temp_shifted_bits := temp_frac(shift_amount - 1 downto 0);
            else
                aligned_frac_b <= (others => '0');
                temp_shifted_bits := temp_frac;
            end if;
        else
            -- 'b' の指数が大きい場合、'a' の仮数をシフト
            aligned_frac_b <= stage1_frac_b & "0000"; -- GRSビットのために4ビット拡張
            temp_frac := stage1_frac_a & "0000"; -- 一時的な変数に格納
            if shift_amount < FRAC_WIDTH + 5 then
                aligned_frac_a <= ('0' & temp_frac) srl shift_amount;
                temp_shifted_bits := temp_frac(shift_amount - 1 downto 0);
            else
                aligned_frac_a <= (others => '0');
                temp_shifted_bits := temp_frac;
            end if;
        end if;

        -- スティッキービットの計算
        sticky_bit <= or_reduce(temp_shifted_bits);
    end process;

    -- 加算・減算操作
    process(aligned_frac_a, aligned_frac_b, reg_stage1_sign_a, reg_stage1_sign_b)
    begin
        if reg_stage1_sign_a = reg_stage1_sign_b then
            -- 符号が同じ場合は加算
            sum_frac <= std_logic_vector(unsigned(aligned_frac_a) + unsigned(aligned_frac_b));
            stage2_sign_res <= reg_stage1_sign_a;
        else
            -- 符号が異なる場合は減算
            if unsigned(aligned_frac_a) >= unsigned(aligned_frac_b) then
                sum_frac <= std_logic_vector(unsigned(aligned_frac_a) - unsigned(aligned_frac_b));
                stage2_sign_res <= reg_stage1_sign_a;
            else
                sum_frac <= std_logic_vector(unsigned(aligned_frac_b) - unsigned(aligned_frac_a));
                stage2_sign_res <= reg_stage1_sign_b;
            end if;
        end if;
    end process;

    -- 正規化処理（先頭の1の位置を検出）:
    --  whileループを使用せず、リーディング・ワン・ディテクタ（Leading One Detector） を使用して、
    --  先頭の '1' の位置を検出します。
    --  これにより、whileループを使わずに正規化のためのシフト量を計算できます。
    process(sum_frac)
    begin
        leading_one_position <= 0;
        for i in sum_frac'low to sum_frac'high loop
            if sum_frac(sum_frac'high - i) = '1' and leading_one_position = 0 then
                leading_one_position <= sum_frac'high - i + 1;
            end if;
        end loop;
    end process;

    -- 仮数と指数の調整
    process(sum_frac, leading_one_position, larger_exp)
    begin
        if leading_one_position > 0 then
            normalized_exp <= larger_exp + (leading_one_position - (FRAC_WIDTH + 5));
            if normalized_exp >= 255 then
                normalized_exp <= 255;
                result_is_inf <= '1';   -- オーバーフロー：Infinityを返す
            elsif normalized_exp <= 0 then
                normalized_exp <= 0;
                result_is_zero <= '1';  -- アンダーフロー：ゼロを返す
            else
                result_is_inf <= '0';
                result_is_zero <= '0';
            end if;
            normalized_frac <= sum_frac(sum_frac'high downto sum_frac'high - (FRAC_WIDTH + 4)) sll (FRAC_WIDTH + 5 - leading_one_position);
        else
            normalized_exp <= 0;
            normalized_frac <= (others => '0');
            result_is_zero <= '1';
            result_is_inf <= '0';
        end if;
    end process;

    -- 丸め処理の適用
    process(normalized_frac, sticky_bit)
    begin
        if normalized_frac(FRAC_WIDTH + 1) = '1' then  -- ガードビット
            if (normalized_frac(FRAC_WIDTH) = '1') or (sticky_bit = '1') then
                -- 仮数に1を加算
                normalized_frac(FRAC_WIDTH + 4 downto FRAC_WIDTH + 1) <=
                    std_logic_vector(unsigned(normalized_frac(FRAC_WIDTH + 4 downto FRAC_WIDTH + 1)) + 1);
            end if;
        end if;
    end process;

    -- 最終結果の計算
    process(is_nan_a, is_nan_b, is_inf_a, is_inf_b, result_is_inf, result_is_zero, stage2_sign_res, normalized_exp, normalized_frac)
    begin
        if is_nan_a = '1' or is_nan_b = '1' then
            -- NaNの処理
            final_result <= "011111111" & "10000000000000000000000"; -- NaNを表すビット列
        elsif is_inf_a = '1' or is_inf_b = '1' or result_is_inf = '1' then
            -- Infinityの処理
            final_result <= stage2_sign_res & "11111111" & (others => '0'); -- Infinityを表すビット列
        elsif result_is_zero = '1' then
            -- ゼロの処理
            final_result <= stage2_sign_res & (others => '0');
        else
            -- 通常の結果
            final_result <= stage2_sign_res & std_logic_vector(to_unsigned(normalized_exp, EXP_WIDTH)) & normalized_frac(FRAC_WIDTH downto 1);
        end if;
    end process;

    -- クロック同期レジスタ（パイプラインレジスタ）
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
            reg_stage1_sign_a <= stage1_sign_a;
            reg_stage1_sign_b <= stage1_sign_b;
            reg_stage1_exp_a <= stage1_exp_a;
            reg_stage1_exp_b <= stage1_exp_b;
            reg_stage1_frac_a <= stage1_frac_a;
            reg_stage1_frac_b <= stage1_frac_b;
            reg_stage1_exp_diff <= exp_diff;

            -- パイプラインステージ2のレジスタ更新
            reg_stage2_sign_res <= stage2_sign_res;
            reg_stage2_exp_res <= normalized_exp;
            reg_stage2_frac_res <= normalized_frac;

            -- 最終結果の格納
            reg_result <= final_result;
        end if;
    end process;

    -- 出力
    result <= reg_result;
end rtl;

