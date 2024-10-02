library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity FPAdder is
    Port (
        a       : in  std_logic_vector(31 downto 0); -- 32ビット入力 a
        b       : in  std_logic_vector(31 downto 0); -- 32ビット入力 b
        result  : out std_logic_vector(31 downto 0)  -- 32ビット結果
    );
end FPAdder;

architecture Behavioral of FPAdder is
    -- 符号、指数、仮数のビット数
    constant EXP_WIDTH : integer := 8;
    constant FRAC_WIDTH : integer := 23;
    constant BIAS : integer := 127;

    -- 信号の宣言
    signal sign_a, sign_b, sign_res : std_logic;
    signal exp_a, exp_b, exp_res : integer;
    signal frac_a, frac_b, frac_res : std_logic_vector(FRAC_WIDTH downto 0); -- 1+23ビット（隠れビット含む）

    signal aligned_frac_a, aligned_frac_b : std_logic_vector(FRAC_WIDTH + 1 downto 0); -- アラインメント後
    signal sum_frac : std_logic_vector(FRAC_WIDTH + 2 downto 0); -- 和の結果 (ゲートレベルの桁上がり処理用)
    signal shift_amount : integer;

begin
    process(a, b)
    begin
        -- 1. 入力分解
        sign_a <= a(31);
        sign_b <= b(31);
        exp_a <= to_integer(unsigned(a(30 downto 23))) - BIAS;
        exp_b <= to_integer(unsigned(b(30 downto 23))) - BIAS;
        frac_a <= "1" & a(22 downto 0); -- 隠れビットを追加
        frac_b <= "1" & b(22 downto 0); -- 隠れビットを追加

        -- 2. 指数アラインメント
        if exp_a > exp_b then
            shift_amount := exp_a - exp_b;
            exp_res := exp_a;
            aligned_frac_a <= frac_a & '0';
            aligned_frac_b <= std_logic_vector(shift_right(unsigned(frac_b & '0'), shift_amount));
        else
            shift_amount := exp_b - exp_a;
            exp_res := exp_b;
            aligned_frac_a <= std_logic_vector(shift_right(unsigned(frac_a & '0'), shift_amount));
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
            exp_res := exp_res + 1;
        elsif sum_frac(FRAC_WIDTH + 1) = '0' then
            while sum_frac(FRAC_WIDTH + 1) = '0' and exp_res > -BIAS loop
                sum_frac := std_logic_vector(shift_left(unsigned(sum_frac), 1));
                exp_res := exp_res - 1;
            end loop;
        end if;

        -- 5. 結果の生成
        result <= sign_res & std_logic_vector(to_unsigned(exp_res + BIAS, EXP_WIDTH)) & sum_frac(FRAC_WIDTH downto 1);
    end process;
end Behavioral;

