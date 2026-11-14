import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { LoginStyle as S } from "../Login/Login.styled";
import { signUp } from "../../api/auth";
import type { SignUpRole } from "../../api/types";

const ROLES: { value: SignUpRole; label: string }[] = [
  { value: "Client", label: "고객" },
  { value: "Owner", label: "사장님" },
  { value: "Delivery", label: "라이더" },
];

const CreateAccount = () => {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [role, setRole] = useState<SignUpRole>("Client");
  const [error, setError] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const canClick =
    email.trim().length > 0 &&
    password.length >= 8 &&
    name.trim().length > 0 &&
    !loading;

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!canClick) return;

    setError(null);
    setSuccessMessage(null);
    setLoading(true);
    try {
      await signUp({
        email: email.trim(),
        password,
        name: name.trim(),
        role,
      });
      setSuccessMessage(
        "계정이 생성되었습니다. 이메일 인증 후 로그인해 주세요.",
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : "회원가입에 실패했습니다.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <S.Wrapper>
      <S.Card>
        <S.Logo>Food Delivery</S.Logo>
        <S.Form onSubmit={onSubmit}>
          <S.Input
            type="text"
            placeholder="이름"
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoComplete="name"
          />
          <S.Input
            type="email"
            placeholder="이메일"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            autoComplete="email"
          />
          <S.Input
            type="password"
            placeholder="비밀번호 (영문·숫자·특수문자 8~15자)"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
          />
          <select
            value={role}
            onChange={(e) => setRole(e.target.value as SignUpRole)}
            style={{
              width: "100%",
              height: 44,
              border: "1px solid #d1d5db",
              borderRadius: 8,
              padding: "0 12px",
              fontSize: 14,
              background: "#fff",
            }}
          >
            {ROLES.map((r) => (
              <option key={r.value} value={r.value}>
                {r.label}
              </option>
            ))}
          </select>
          {error && <S.ErrorText>{error}</S.ErrorText>}
          {!error && successMessage && (
            <S.ErrorText style={{ color: "#059669" }}>{successMessage}</S.ErrorText>
          )}
          <S.Button type="submit" $canClick={canClick} $loading={loading} disabled={!canClick}>
            {loading ? "가입 중..." : "계정 만들기"}
          </S.Button>
        </S.Form>
        <S.SignupText>
          이미 계정이 있으신가요? <Link to="/">로그인</Link>
        </S.SignupText>
      </S.Card>
    </S.Wrapper>
  );
};

export default CreateAccount;
