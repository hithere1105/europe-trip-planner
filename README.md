# 유럽 여행 플래너

일정·지도 경로·예산·준비물을 짜는 한 장짜리 웹페이지입니다. (`index.html`)

- 저장소 연결(선택): Supabase 프로젝트를 만들고 `supabase-setup.sql`을 SQL Editor에서 한 번 실행한 뒤,
  페이지의 **메모/데이터 → 저장소 설정**에 Project URL과 anon key를 붙여넣으면 닉네임 + 코드 2자리로 플랜을 저장/불러올 수 있어요.
- 저장소를 연결하지 않으면 일정은 각자 브라우저에만 저장됩니다.
- 모두가 같은 저장소를 쓰게 하려면 `index.html` 안의 `SB_URL_DEFAULT`, `SB_KEY_DEFAULT` 두 줄에 값을 직접 적어 두세요.
