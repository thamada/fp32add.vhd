--
-- Copyright(c) 2024 by Tsuyoshi Hamada
--
-------------------------------------------------------------------------
-- クロック同期式単精度浮動小数点加算器(IEEE 754形式)
--
--   fp32add_simple.vhdをclk同期式に修正した実装です。
--   クロック同期化: クロック信号 clk の立ち上がりエッジでプロセスを実行
--   リセット信号: rst が 1 の場合、出力 result は初期化
--   レジスタ: 結果はレジスタ reg_result に格納され、次のクロックサイクル
--   で出力 result に反映されます。
-------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity FPAdder is
    Port (
        clk : in std_logic;
        a   : in std_logic_vector(31 downto 0);
        b   : in std_logic_vector(31 downto 0);
        sum : out std_logic_vector(31 downto 0)
    );
end FPAdder;

architecture Behavioral of FPAdder is

    -- パイプラインステージ間の信号を宣言
    -- ステージ1からステージ2への信号
    signal s1_a_sign        : std_logic;
    signal s1_a_exp         : std_logic_vector(7 downto 0);
    signal s1_a_frac        : std_logic_vector(23 downto 0);
    signal s1_b_sign        : std_logic;
    signal s1_b_exp         : std_logic_vector(7 downto 0);
    signal s1_b_frac        : std_logic_vector(23 downto 0);

    -- ステージ2からステージ3への信号
    signal s2_sign_result   : std_logic;
    signal s2_exp_result    : std_logic_vector(7 downto 0);
    signal s2_mantissa_sum  : std_logic_vector(24 downto 0);

    -- 正規化後の結果
    signal normalized_sign  : std_logic;
    signal normalized_exp   : std_logic_vector(7 downto 0);
    signal normalized_frac  : std_logic_vector(22 downto 0);

    -- ビットごとの演算で使用する関数を宣言
    function compare_vectors(a, b : std_logic_vector) return integer;
    function add_vectors(a, b : std_logic_vector) return std_logic_vector;
    function subtract_vectors(a, b : std_logic_vector) return std_logic_vector;
    function shift_right(v : std_logic_vector; n : integer) return std_logic_vector;

begin

    -- ビットごとの比較関数
    function compare_vectors(a, b : std_logic_vector) return integer is
        variable result : integer := 0;
    begin
        for i in a'range loop
            if a(i) = '1' and b(i) = '0' then
                result := 1;
                return result;
            elsif a(i) = '0' and b(i) = '1' then
                result := -1;
                return result;
            end if;
        end loop;
        return result; -- 0の場合は等しい
    end function;

    -- ビットごとの加算関数
    function add_vectors(a, b : std_logic_vector) return std_logic_vector is
        variable sum    : std_logic_vector(a'range);
        variable carry  : std_logic := '0';
        variable temp   : std_logic;
    begin
        for i in a'reverse_range loop
            temp := a(i) xor b(i) xor carry;
            carry := (a(i) and b(i)) or (a(i) and carry) or (b(i) and carry);
            sum(i) := temp;
        end loop;
        return sum;
    end function;

    -- ビットごとの減算関数
    function subtract_vectors(a, b : std_logic_vector) return std_logic_vector is
        variable diff   : std_logic_vector(a'range);
        variable borrow : std_logic := '0';
        variable temp   : std_logic;
    begin
        for i in a'reverse_range loop
            temp := a(i) xor b(i) xor borrow;
            borrow := (not a(i) and b(i)) or ((not a(i) or b(i)) and borrow);
            diff(i) := temp;
        end loop;
        return diff;
    end function;

    -- ビットごとの右シフト関数
    function shift_right(v : std_logic_vector; n : integer) return std_logic_vector is
        variable shifted : std_logic_vector(v'range) := v;
    begin
        for i in 1 to n loop
            shifted := '0' & shifted(shifted'high downto 1);
        end loop;
        return shifted;
    end function;

    -- ステージ1 組み合わせ回路：オペランドの分解と整列
    -- オペランドaの分解
    s1_a_sign_comb : s1_a_sign <= a(31);
    s1_a_exp_comb  : s1_a_exp  <= a(30 downto 23);
    s1_a_frac_comb : s1_a_frac <= '1' & a(22 downto 0); -- 仮数部に隠れた1を追加

    -- オペランドbの分解
    s1_b_sign_comb : s1_b_sign <= b(31);
    s1_b_exp_comb  : s1_b_exp  <= b(30 downto 23);
    s1_b_frac_comb : s1_b_frac <= '1' & b(22 downto 0); -- 仮数部に隠れた1を追加

    -- ステージ1 パイプラインレジスタ
    process(clk)
    begin
        if rising_edge(clk) then
            s1_a_sign <= s1_a_sign;
            s1_a_exp  <= s1_a_exp;
            s1_a_frac <= s1_a_frac;
            s1_b_sign <= s1_b_sign;
            s1_b_exp  <= s1_b_exp;
            s1_b_frac <= s1_b_frac;
        end if;
    end process;

    -- ステージ2 組み合わせ回路：指数の比較と仮数の整列
    signal exp_diff        : std_logic_vector(7 downto 0);
    signal mantissa_small  : std_logic_vector(24 downto 0);
    signal mantissa_large  : std_logic_vector(24 downto 0);
    signal sign_small      : std_logic;
    signal sign_large      : std_logic;
    signal exp_large       : std_logic_vector(7 downto 0);

    exp_compare: process(s1_a_exp, s1_b_exp, s1_a_frac, s1_b_frac, s1_a_sign, s1_b_sign)
    begin
        if compare_vectors(s1_a_exp, s1_b_exp) = 1 then
            exp_diff        <= subtract_vectors(s1_a_exp, s1_b_exp);
            exp_large       <= s1_a_exp;
            mantissa_large  <= '0' & s1_a_frac; -- 上位ビット拡張
            mantissa_small  <= '0' & s1_b_frac;
            sign_large      <= s1_a_sign;
            sign_small      <= s1_b_sign;
        else
            exp_diff        <= subtract_vectors(s1_b_exp, s1_a_exp);
            exp_large       <= s1_b_exp;
            mantissa_large  <= '0' & s1_b_frac;
            mantissa_small  <= '0' & s1_a_frac;
            sign_large      <= s1_b_sign;
            sign_small      <= s1_a_sign;
        end if;
    end process;

    -- 仮数の整列（ビットごとのシフト）
    signal shifted_mantissa_small : std_logic_vector(24 downto 0);
    shift_mantissa: process(exp_diff, mantissa_small)
        variable shift_amount : integer := 0;
    begin
        shift_amount := 0;
        for i in exp_diff'range loop
            if exp_diff(i) = '1' then
                shift_amount := shift_amount + 2 ** (exp_diff'length - 1 - i);
            end if;
        end loop;
        shifted_mantissa_small <= shift_right(mantissa_small, shift_amount);
    end process;

    -- 仮数の加算または減算（ビットごとの演算）
    add_sub_mantissa: process(mantissa_large, shifted_mantissa_small, sign_large, sign_small)
        variable temp_sum   : std_logic_vector(24 downto 0);
        variable temp_diff  : std_logic_vector(24 downto 0);
    begin
        if sign_large = sign_small then
            -- 加算
            temp_sum := add_vectors(mantissa_large, shifted_mantissa_small);
            s2_mantissa_sum <= temp_sum;
            s2_sign_result  <= sign_large;
            s2_exp_result   <= exp_large;
        else
            -- 減算
            if compare_vectors(mantissa_large, shifted_mantissa_small) >= 0 then
                temp_diff := subtract_vectors(mantissa_large, shifted_mantissa_small);
                s2_mantissa_sum <= temp_diff;
                s2_sign_result  <= sign_large;
                s2_exp_result   <= exp_large;
            else
                temp_diff := subtract_vectors(shifted_mantissa_small, mantissa_large);
                s2_mantissa_sum <= temp_diff;
                s2_sign_result  <= sign_small;
                s2_exp_result   <= exp_large;
            end if;
        end if;
    end process;

    -- ステージ2 パイプラインレジスタ
    process(clk)
    begin
        if rising_edge(clk) then
            normalized_sign  <= s2_sign_result;
            normalized_exp   <= s2_exp_result;
            normalized_frac  <= s2_mantissa_sum(23 downto 1);
        end if;
    end process;

    -- ステージ3 組み合わせ回路：正規化と結果のパッキング
    normalize: process(s2_mantissa_sum, normalized_exp)
        variable leading_one_pos : integer := -1;
        variable adjusted_exp    : std_logic_vector(7 downto 0);
        variable adjusted_frac   : std_logic_vector(22 downto 0);
    begin
        -- 先頭の1の検出
        for i in s2_mantissa_sum'range loop
            if s2_mantissa_sum(i) = '1' and leading_one_pos = -1 then
                leading_one_pos := i;
            end if;
        end loop;

        if leading_one_pos /= -1 then
            -- 指数の調整
            adjusted_exp := add_vectors(normalized_exp, std_logic_vector(to_unsigned(leading_one_pos - 24, 8)));
            -- 仮数の調整
            adjusted_frac := s2_mantissa_sum(leading_one_pos - 1 downto leading_one_pos - 23);
        else
            adjusted_exp := (others => '0');
            adjusted_frac := (others => '0');
        end if;

        normalized_exp  <= adjusted_exp;
        normalized_frac <= adjusted_frac;
    end process;

    -- ステージ3 パイプラインレジスタ（出力）
    process(clk)
    begin
        if rising_edge(clk) then
            sum <= normalized_sign & normalized_exp & normalized_frac;
        end if;
    end process;

end Behavioral;
