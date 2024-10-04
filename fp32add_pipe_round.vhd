-- Copyright(c) 2024 by Tsuyoshi Hamada
--
-- 丸め処理を追加した、パイプライン構造のIEEE 754単精度浮動小数点加算器のVHDLコード
-- 丸め処理は、IEEE 754標準の「最近接偶数への丸め」（Round to Nearest, Even）を実装します。これは最も一般的な丸めモードです。
-- 丸め処理ですがRound-bit, Guard-bit, Stickey-bitの3ビットテーブルによるRound to Nearest Evenは実装していません。

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

architecture rtl of fp32add_pipe_roundis
    -- 符号、指数、仮数のビット数
    constant EXP_WIDTH : integer := 8;
    constant FRAC_WIDTH : integer := 23;
    constant TOTAL_WIDTH : integer := 32;
    constant BIAS : std_logic_vector(EXP_WIDTH - 1 downto 0) := "01111111"; -- 127をバイナリで表現

    -- パイプラインレジスタ
    signal reg_stage1_sign_a, reg_stage1_sign_b: std_logic;
    signal reg_stage1_exp_a, reg_stage1_exp_b: std_logic_vector(EXP_WIDTH - 1 downto 0);
    signal reg_stage1_frac_a, reg_stage1_frac_b: std_logic_vector(FRAC_WIDTH downto 0);
    signal reg_stage1_diff : std_logic_vector(EXP_WIDTH - 1 downto 0);

    signal reg_stage2_sign_res: std_logic;
    signal reg_stage2_exp_res: std_logic_vector(EXP_WIDTH - 1 downto 0);
    signal reg_stage2_sum_frac: std_logic_vector(FRAC_WIDTH + 2 downto 0);

    signal aligned_frac_a, aligned_frac_b : std_logic_vector(FRAC_WIDTH + 1 downto 0); -- アラインメント後
    signal sum_frac : std_logic_vector(FRAC_WIDTH + 2 downto 0); -- 和の結果
    signal shift_amount : std_logic_vector(EXP_WIDTH - 1 downto 0);

    -- 最終出力レジスタ
    signal reg_result : std_logic_vector(31 downto 0);

begin
    -- クロック同期レジスタ
    process (clk, rst)
    begin
        if rst = '1' then
            reg_stage1_sign_a <= '0';
            reg_stage1_sign_b <= '0';
            reg_stage1_exp_a <= (others => '0');
            reg_stage1_exp_b <= (others => '0');
            reg_stage1_frac_a <= (others => '0');
            reg_stage1_frac_b <= (others => '0');
            reg_stage1_diff <= (others => '0');

            reg_stage2_sign_res <= '0';
            reg_stage2_exp_res <= (others => '0');
            reg_stage2_sum_frac <= (others => '0');
            reg_result <= (others => '0'); -- リセット時は0に
        elsif rising_edge(clk) then
            -- パイプラインステージ1のレジスタ
            reg_stage1_sign_a <= a(31);
            reg_stage1_sign_b <= b(31);
            reg_stage1_exp_a <= a(30 downto 23);
            reg_stage1_exp_b <= b(30 downto 23);
            reg_stage1_frac_a <= "1" & a(22 downto 0); -- 隠れビットを追加
            reg_stage1_frac_b <= "1" & b(22 downto 0); -- 隠れビットを追加
            reg_stage1_diff <= std_logic_vector(unsigned(a(30 downto 23)) - unsigned(b(30 downto 23)));

            -- パイプラインステージ2のレジスタ
            reg_stage2_sign_res <= (reg_stage1_sign_a and reg_stage1_sign_b) or (reg_stage1_sign_a and not reg_stage1_sign_b) or (not reg_stage1_sign_a and reg_stage1_sign_b);
            reg_stage2_exp_res <= reg_stage1_exp_a;
            reg_stage2_sum_frac <= sum_frac;

            -- 丸め処理を適用し最終結果をレジスタに格納
            if reg_stage2_sum_frac(0) = '1' then
                -- 最下位ビットが1の場合は丸めを行う
                reg_result <= reg_stage2_sign_res & reg_stage2_exp_res & (std_logic_vector(unsigned(reg_stage2_sum_frac(FRAC_WIDTH + 1 downto 1)) + 1));
            else
                -- 丸めなしの場合はそのまま格納
                reg_result <= reg_stage2_sign_res & reg_stage2_exp_res & reg_stage2_sum_frac(FRAC_WIDTH downto 1);
            end if;
        end if;
    end process;

    -- 組み合わせ回路：指数アラインメント
    aligned_frac_a <= reg_stage1_frac_a & '0';
    aligned_frac_b <= reg_stage1_frac_b & '0';

    for i in 0 to EXP_WIDTH - 1 loop
        if reg_stage1_diff(i) = '1' then
            aligned_frac_b <= '0' & aligned_frac_b(FRAC_WIDTH + 1 downto 1);
        end if;
    end loop;

    -- 組み合わせ回路：加算・減算操作
    if reg_stage1_sign_a = reg_stage1_sign_b then
        sum_frac <= ('0' & aligned_frac_a) + ('0' & aligned_frac_b);
    else
        if aligned_frac_a > aligned_frac_b then
            sum_frac <= ('0' & aligned_frac_a) - ('0' & aligned_frac_b);
        else
            sum_frac <= ('0' & aligned_frac_b) - ('0' & aligned_frac_a);
        end if;
    end if;

    -- 正規化
    if sum_frac(FRAC_WIDTH + 2) = '1' then
        sum_frac <= '0' & sum_frac(FRAC_WIDTH + 2 downto 1);
        reg_stage2_exp_res <= std_logic_vector(unsigned(reg_stage2_exp_res) + 1);
    elsif sum_frac(FRAC_WIDTH + 1) = '0' then
        while sum_frac(FRAC_WIDTH + 1) = '0' and unsigned(reg_stage2_exp_res) > 0 loop
            sum_frac <= sum_frac(FRAC_WIDTH + 1 downto 0) & '0';
            reg_stage2_exp_res <= std_logic_vector(unsigned(reg_stage2_exp_res) - 1);
        end loop;
    end if;

    -- 出力
    result <= reg_result;
end rtl;

