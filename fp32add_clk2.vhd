--
-- Copyright(c) 2024 by Tsuyoshi Hamada
--
-------------------------------------------------------------------------
-- fp32add_clk.vhdの改良版
-- 整数（integer）型 を使わずにstd_logicやstd_logic_vectorで表現するように変更したVHDL実装
-- 整数操作はstd_logic_vectorで表現し、unsignedとstd_logic_vectorのキャストを使用しています。
-- シフト量: shift_amountもstd_logic_vectorで扱っています。
-- unsignedとstd_logic_vectorの変換: 数値操作を行う際、unsigned()関数を使いstd_logic_vectorとの間で変換を行っています。
-------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fp32add_clk2 is
    Port (
        clk     : in  std_logic;                -- クロック信号
        rst     : in  std_logic;                -- リセット信号
        a       : in  std_logic_vector(31 downto 0); -- 32ビット入力 a
        b       : in  std_logic_vector(31 downto 0); -- 32ビット入力 b
        result  : out std_logic_vector(31 downto 0)  -- 32ビット結果
    );
end fp32add_clk2;

architecture rtl of fp32add_clk2 is
    -- 符号、指数、仮数のビット数
    constant EXP_WIDTH : integer := 8;
    constant FRAC_WIDTH : integer := 23;
    constant BIAS : std_logic_vector(EXP_WIDTH - 1 downto 0) := std_logic_vector(to_unsigned(127, EXP_WIDTH));

    -- 信号の宣言
    signal sign_a, sign_b, sign_res : std_logic;
    signal exp_a, exp_b, exp_res : std_logic_vector(EXP_WIDTH - 1 downto 0);
    signal frac_a, frac_b : std_logic_vector(FRAC_WIDTH downto 0); -- 1+23ビット（隠れビット含む）
    signal aligned_frac_a, aligned_frac_b : std_logic_vector(FRAC_WIDTH + 1 downto 0); -- アラインメント後
    signal sum_frac : std_logic_vector(FRAC_WIDTH + 2 downto 0); -- 和の結果
    signal shift_amount : std_logic_vector(EXP_WIDTH - 1 downto 0);
    signal reg_result : std_logic_vector(31 downto 0); -- 結果を格納するレジスタ
    signal exp_diff : std_logic_vector(EXP_WIDTH - 1 downto 0);
begin
    process(clk, rst)
    begin
        if rst = '1' then
            reg_result <= (others => '0'); -- リセット時は0に
        elsif rising_edge(clk) then
            -- 1. 入力分解
            sign_a <= a(31);
            sign_b <= b(31);
            exp_a <= a(30 downto 23);
            exp_b <= b(30 downto 23);
            frac_a <= "1" & a(22 downto 0); -- 隠れビットを追加
            frac_b <= "1" & b(22 downto 0); -- 隠れビットを追加

            -- 2. 指数アラインメント
            if unsigned(exp_a) > unsigned(exp_b) then
                exp_diff := std_logic_vector(unsigned(exp_a) - unsigned(exp_b));
                exp_res := exp_a;
                aligned_frac_a <= frac_a & '0';
                aligned_frac_b <= std_logic_vector(shift_right(unsigned(frac_b & '0'), to_integer(unsigned(exp_diff))));
            else
                exp_diff := std_logic_vector(unsigned(exp_b) - unsigned(exp_a));
                exp_res := exp_b;
                aligned_frac_a <= std_logic_vector(shift_right(unsigned(frac_a & '0'), to_integer(unsigned(exp_diff))));
                aligned_frac_b <= frac_b & '0';
            end if;

            -- 3. 符号付き仮数の加算または減算
            if sign_a = sign_b then
                sum_frac <= std_logic_vector(unsigned(aligned_frac_a) + unsigned(aligned_frac_b));
                sign_res <= sign_a;
            else
                if unsigned(aligned_frac_a) > unsigned(aligned_frac_b) then
                    sum_frac <= std_logic_vector(unsigned(aligned_frac_a) - unsigned(aligned_frac_b));
                    sign_res <= sign_a;
                else
                    sum_frac <= std_logic_vector(unsigned(aligned_frac_b) - unsigned(aligned_frac_a));
                    sign_res <= sign_b;
                end if;
            end if;

            -- 4. 正規化
            if sum_frac(FRAC_WIDTH + 2) = '1' then
                sum_frac := std_logic_vector(shift_right(unsigned(sum_frac), 1));
                exp_res := std_logic_vector(unsigned(exp_res) + 1);
            elsif sum_frac(FRAC_WIDTH + 1) = '0' then
                while sum_frac(FRAC_WIDTH + 1) = '0' and unsigned(exp_res) > 0 loop
                    sum_frac := std_logic_vector(shift_left(unsigned(sum_frac), 1));
                    exp_res := std_logic_vector(unsigned(exp_res) - 1);
                end loop;
            end if;

            -- 5. 結果の生成
            reg_result <= sign_res & exp_res & sum_frac(FRAC_WIDTH downto 1);
        end if;
    end process;

    -- 出力
    result <= reg_result;
end rtl;
