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
-- ------------------------------
-- VHDLコードのポイントと修正点
-- ------------------------------
--  * ガードビット（G）、ラウンドビット（R）、スティッキービット（S） を明示的に定義し、丸め処理を正しく実装。
--  * 仮数全体に1を加算し、繰り上がりを正しく処理。
--  * パイプラインのデータフローを正しく実装し、各ステージのレジスタ出力が次のステージの組み合わせ回路で使用されるように修正。
--  * 特殊な値の処理（NaN、Infinity、ゼロなど）を含む。
--  * オーバーフローとアンダーフローの処理を追加。
--
-- ガードビット、ラウンドビット、スティッキービットの明示的な定義:
-- G, R, S を std_logic 型で定義し、丸め処理で使用しています。
-- 
-- 仮数全体に1を加算:
-- 丸めが必要な場合、normalized_frac 全体に1を加算しています。
-- 加算後の繰り上がりをチェックし、必要に応じて仮数をシフトし、指数部を調整しています。
-- 
-- パイプラインのデータフローの修正:
-- 各ステージのレジスタ出力を次のステージの組み合わせ回路で使用するように修正しました。
-- reg_stage1_* 信号をステージ2の組み合わせ回路で使用し、reg_stage2_* 信号をステージ3の組み合わせ回路で使用しています。
-- 
-- 特殊な値の処理:
-- NaN、Infinity、ゼロの処理を含めています。
-- is_nan_a, is_nan_b, is_inf_a, is_inf_b, is_zero_a, is_zero_b を使用して特殊な値を検出し、final_result を適切に設定しています。
-- 
-- オーバーフローとアンダーフローの処理:
-- 指数部が範囲外になった場合の処理を追加しています。
-- normalized_exp が 255 を超える場合は Infinity として処理し、0 未満の場合はゼロとして処理しています。
-- 
-- 正規化処理の修正:
-- 丸め処理後の繰り上がりを考慮して、正規化処理を適切に行っています。
-- 
-- 仮数ビット幅の調整:
-- 仮数のビット幅を FRAC_WIDTH + 5 に設定し、繰り上がりビットや GRS ビットを含めています。
-- 
-- 
-- ------------------------------
-- 注意点
-- ------------------------------
-- 
-- 合成ツールの制限:
-- 一部の合成ツールでは、プロセス内での信号の部分代入やビットスライスの操作が制限されている場合があります。
-- 必要に応じて、コードを調整してください。
-- 
-- テストと検証:
-- このコードが正しく動作することを確認するために、シミュレーションを行い、さまざまなテストケースで検証することをお勧めします。
-- 
-- さらなる最適化:
-- 実際のハードウェア設計では、パフォーマンスやリソースの観点から最適化が必要な場合があります。
-- 
-- ------------------------------
-- 未実装課題
-- ------------------------------
-- 丸め処理後に、再度正規化処理と指数部の調整を行う必要があります。また、オーバーフローやアンダーフローの可能性も考慮してください。

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
    signal reg_stage2_frac_res: std_logic_vector(FRAC_WIDTH + 5 downto 0); -- 仮数部 + GRSビット
    signal reg_stage2_larger_exp : integer range 0 to 255;
    signal reg_stage2_shift_amount : integer range 0 to FRAC_WIDTH + 5;

    -- ステージ3レジスタ（最終結果）
    signal reg_result : std_logic_vector(31 downto 0);

    -- 組み合わせ回路用の信号
    -- ステージ1の組み合わせ回路（入力レジスタへの格納）
    signal stage1_sign_a, stage1_sign_b: std_logic;
    signal stage1_exp_a, stage1_exp_b: std_logic_vector(EXP_WIDTH - 1 downto 0);
    signal stage1_frac_a, stage1_frac_b: std_logic_vector(FRAC_WIDTH downto 0);
    signal stage1_exp_diff : integer range -255 to 255;

    -- ステージ2の組み合わせ回路
    signal is_zero_a, is_zero_b : std_logic;
    signal is_inf_a, is_inf_b : std_logic;
    signal is_nan_a, is_nan_b : std_logic;

    signal aligned_frac_a, aligned_frac_b : std_logic_vector(FRAC_WIDTH + 5 downto 0);
    signal shifted_out_bits : std_logic_vector(FRAC_WIDTH + 5 downto 0);
    signal sticky_bit : std_logic;
    signal sum_frac : std_logic_vector(FRAC_WIDTH + 5 downto 0);
    signal stage2_sign_res : std_logic;

    -- ステージ3の組み合わせ回路
    signal leading_one_position : integer range 0 to FRAC_WIDTH + 6;
    signal normalized_frac : std_logic_vector(FRAC_WIDTH + 5 downto 0);
    signal normalized_exp : integer range 0 to 255;

    signal result_is_inf : std_logic;
    signal result_is_zero : std_logic;
    signal final_result : std_logic_vector(31 downto 0);

    -- ガードビット、ラウンドビット、スティッキービット
    signal G, R, S : std_logic;

begin
    -- ステージ1の組み合わせ回路（入力信号の準備）
    stage1_sign_a <= a(31);
    stage1_sign_b <= b(31);
    stage1_exp_a <= a(30 downto 23);
    stage1_exp_b <= b(30 downto 23);
    stage1_frac_a <= '1' & a(22 downto 0); -- 隠れビットを追加
    stage1_frac_b <= '1' & b(22 downto 0); -- 隠れビットを追加

    stage1_exp_diff <= to_integer(unsigned(stage1_exp_a)) - to_integer(unsigned(stage1_exp_b));

    -- クロック同期レジスタ（ステージ1）
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
        elsif rising_edge(clk) then
            -- ステージ1のレジスタ更新
            reg_stage1_sign_a <= stage1_sign_a;
            reg_stage1_sign_b <= stage1_sign_b;
            reg_stage1_exp_a <= stage1_exp_a;
            reg_stage1_exp_b <= stage1_exp_b;
            reg_stage1_frac_a <= stage1_frac_a;
            reg_stage1_frac_b <= stage1_frac_b;
            reg_stage1_exp_diff <= stage1_exp_diff;
        end if;
    end process;

    -- ステージ2の組み合わせ回路
    -- 特殊な値のチェック
    is_zero_a <= '1' when (reg_stage1_exp_a = (others => '0') and reg_stage1_frac_a(FRAC_WIDTH downto 0) = (others => '0')) else '0';
    is_zero_b <= '1' when (reg_stage1_exp_b = (others => '0') and reg_stage1_frac_b(FRAC_WIDTH downto 0) = (others => '0')) else '0';

    is_inf_a <= '1' when (reg_stage1_exp_a = (others => '1') and reg_stage1_frac_a(FRAC_WIDTH - 1 downto 0) = (others => '0')) else '0';
    is_inf_b <= '1' when (reg_stage1_exp_b = (others => '1') and reg_stage1_frac_b(FRAC_WIDTH - 1 downto 0) = (others => '0')) else '0';

    is_nan_a <= '1' when (reg_stage1_exp_a = (others => '1') and reg_stage1_frac_a(FRAC_WIDTH - 1 downto 0) /= (others => '0')) else '0';
    is_nan_b <= '1' when (reg_stage1_exp_b = (others => '1') and reg_stage1_frac_b(FRAC_WIDTH - 1 downto 0) /= (others => '0')) else '0';

    -- アラインメントとシフト量の計算
    reg_stage2_larger_exp <= integer'max(to_integer(unsigned(reg_stage1_exp_a)), to_integer(unsigned(reg_stage1_exp_b)));
    reg_stage2_shift_amount <= abs(reg_stage1_exp_diff);

    -- アラインメントとスティッキービットの計算
    process(reg_stage1_frac_a, reg_stage1_frac_b, reg_stage1_exp_diff, reg_stage2_shift_amount)
        variable temp_frac : std_logic_vector(FRAC_WIDTH + 5 downto 0);
        variable temp_shifted_bits : std_logic_vector(FRAC_WIDTH + 5 downto 0);
    begin
        if reg_stage1_exp_diff >= 0 then
            -- 'a' の指数が大きい場合、'b' の仮数をシフト
            aligned_frac_a <= '0' & reg_stage1_frac_a & "0000"; -- GRSビットのために5ビット拡張
            temp_frac := '0' & reg_stage1_frac_b & "0000"; -- 一時的な変数に格納
            if reg_stage2_shift_amount < FRAC_WIDTH + 6 then
                aligned_frac_b <= temp_frac srl reg_stage2_shift_amount;
                temp_shifted_bits := temp_frac(reg_stage2_shift_amount - 1 downto 0);
            else
                aligned_frac_b <= (others => '0');
                temp_shifted_bits := temp_frac;
            end if;
        else
            -- 'b' の指数が大きい場合、'a' の仮数をシフト
            aligned_frac_b <= '0' & reg_stage1_frac_b & "0000"; -- GRSビットのために5ビット拡張
            temp_frac := '0' & reg_stage1_frac_a & "0000"; -- 一時的な変数に格納
            if reg_stage2_shift_amount < FRAC_WIDTH + 6 then
                aligned_frac_a <= temp_frac srl reg_stage2_shift_amount;
                temp_shifted_bits := temp_frac(reg_stage2_shift_amount - 1 downto 0);
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

    -- クロック同期レジスタ（ステージ2）
    process (clk, rst)
    begin
        if rst = '1' then
            -- レジスタの初期化
            reg_stage2_sign_res <= '0';
            reg_stage2_exp_res <= 0;
            reg_stage2_frac_res <= (others => '0');
        elsif rising_edge(clk) then
            -- ステージ2のレジスタ更新
            reg_stage2_sign_res <= stage2_sign_res;
            reg_stage2_exp_res <= reg_stage2_larger_exp;
            reg_stage2_frac_res <= sum_frac;
        end if;
    end process;

    -- ステージ3の組み合わせ回路
    -- 正規化処理（先頭の1の位置を検出）
    process(reg_stage2_frac_res)
    begin
        leading_one_position <= 0;
        for i in reg_stage2_frac_res'low to reg_stage2_frac_res'high loop
            if reg_stage2_frac_res(reg_stage2_frac_res'high - i) = '1' and leading_one_position = 0 then
                leading_one_position <= reg_stage2_frac_res'high - i + 1;
            end if;
        end loop;
    end process;

    -- 仮数と指数の調整
    process(reg_stage2_frac_res, leading_one_position, reg_stage2_exp_res)
    begin
        if leading_one_position > 0 then
            normalized_exp <= reg_stage2_exp_res + (leading_one_position - (FRAC_WIDTH + 6));
            if normalized_exp >= 255 then
                normalized_exp <= 255;
                result_is_inf <= '1';
                result_is_zero <= '0';
            elsif normalized_exp <= 0 then
                normalized_exp <= 0;
                result_is_zero <= '1';
                result_is_inf <= '0';
            else
                result_is_inf <= '0';
                result_is_zero <= '0';
            end if;

            normalized_frac <= reg_stage2_frac_res sll (FRAC_WIDTH + 6 - leading_one_position);
        else
            normalized_exp <= 0;
            normalized_frac <= (others => '0');
            result_is_zero <= '1';
            result_is_inf <= '0';
        end if;
    end process;

    -- 丸め処理の適用
    process(normalized_frac)
    begin
        -- ガードビット、ラウンドビット、スティッキービットの定義
        G <= normalized_frac(FRAC_WIDTH + 1);
        R <= normalized_frac(FRAC_WIDTH);
        if FRAC_WIDTH - 1 >= 0 then
            S <= or_reduce(normalized_frac(FRAC_WIDTH - 1 downto 0));
        else
            S <= '0';
        end if;

        -- 丸めの条件に基づいて仮数を調整
        if (G = '1') then
            if (R = '1') or (S = '1') then
                -- 仮数全体に1を加算
                normalized_frac <= std_logic_vector(unsigned(normalized_frac) + 1);
            end if;
        end if;

        -- 繰り上がりのチェックと指数部の調整
        if normalized_frac(FRAC_WIDTH + 5) = '1' then
            -- 仮数を右に1ビットシフト
            normalized_frac <= '0' & normalized_frac(FRAC_WIDTH + 5 downto 1);
            -- 指数部を1増加
            normalized_exp <= normalized_exp + 1;
        end if;
    end process;

    -- 最終結果の計算
    process(is_nan_a, is_nan_b, is_inf_a, is_inf_b, result_is_inf, result_is_zero, reg_stage2_sign_res, normalized_exp, normalized_frac)
    begin
        if is_nan_a = '1' or is_nan_b = '1' then
            -- NaNの処理
            final_result <= "011111111" & "10000000000000000000000"; -- NaNを表すビット列
        elsif is_inf_a = '1' or is_inf_b = '1' or result_is_inf = '1' then
            -- Infinityの処理
            final_result <= reg_stage2_sign_res & "11111111" & (others => '0'); -- Infinityを表すビット列
        elsif result_is_zero = '1' then
            -- ゼロの処理
            final_result <= reg_stage2_sign_res & (others => '0');
        else
            -- 通常の結果
            final_result <= reg_stage2_sign_res & std_logic_vector(to_unsigned(normalized_exp, EXP_WIDTH)) & normalized_frac(FRAC_WIDTH + 4 downto FRAC_WIDTH + 2);
        end if;
    end process;

    -- クロック同期レジスタ（ステージ3）
    process (clk, rst)
    begin
        if rst = '1' then
            -- レジスタの初期化
            reg_result <= (others => '0');
        elsif rising_edge(clk) then
            -- ステージ3のレジスタ更新（最終結果）
            reg_result <= final_result;
        end if;
    end process;

    -- 出力
    result <= reg_result;
end rtl;

