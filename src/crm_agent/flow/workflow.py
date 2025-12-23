from __future__ import annotations

from typing import TypedDict, Any, Dict, List
from collections import defaultdict

from langgraph.graph import StateGraph, END

from crm_agent.db.engine import SessionLocal
from crm_agent.db.repo import Repo
from crm_agent.services.targeting import build_target
from crm_agent.rag.retriever import RagRetriever, build_context_text

# stages
ST_BRIEF = "BRIEF"
ST_TARGET_INPUT = "TARGET_INPUT"          # ✅ app.py에서 저장
ST_TARGET_AUDIENCE = "TARGET_AUDIENCE"    # ✅ app.py에서 저장
ST_TARGET = "TARGET"                      # ✅ workflow가 저장(확장본)
ST_RAG = "RAG"
ST_TEMPLATE_CANDIDATES = "TEMPLATE_CANDIDATES"
ST_COMPLIANCE = "COMPLIANCE"
ST_SELECTED_TEMPLATE = "SELECTED_TEMPLATE"
ST_EXECUTION_RESULT = "EXECUTION_RESULT"


try:
    from crm_agent.agents.template_agent import generate_template_candidates
except Exception:
    generate_template_candidates = None

try:
    from crm_agent.agents.compliance import validate_candidates
except Exception:
    validate_candidates = None

try:
    from crm_agent.agents.execution_agent import generate_final_message
except Exception:
    generate_final_message = None


class CRMState(TypedDict, total=False):
    run_id: str
    channel: str
    tone: str

    brief: dict
    target_input: dict           # ✅ 추가
    target_audience: dict        # ✅ 추가

    target: dict
    rag: dict
    candidates: dict
    compliance: dict

    selected_template: dict
    execution_result: dict


def _repo() -> Repo:
    db = SessionLocal()
    return Repo(db)


def _close_repo(repo: Repo) -> None:
    try:
        repo.db.close()
    except Exception:
        pass


def _build_rag_evidence(
        retrieved: Dict[str, Any],
        max_each_source: int = 3,
        max_text_chars: int = 800,
) -> List[Dict[str, Any]]:
    """
    retrieved["matches"] -> evidence[]
    - source(문서)별 최대 N개만 저장
    - text가 너무 길면 잘라서 저장(핸드오프 payload 과대 방지)
    """
    matches = retrieved.get("matches", []) or []
    per_source = defaultdict(int)

    evidence: List[Dict[str, Any]] = []
    for m in matches:
        md = (m.get("metadata") or {})
        source = md.get("source", "UNKNOWN")
        section = md.get("section", "")
        chunk_id = md.get("chunk_id", "")
        text = (md.get("text") or "").strip()

        if not text:
            continue

        if per_source[source] >= max_each_source:
            continue
        per_source[source] += 1

        if len(text) > max_text_chars:
            text = text[:max_text_chars] + "…"

        evidence.append(
            {
                "id": m.get("id", ""),
                "score": float(m.get("score", 0.0)),
                "source": source,
                "section": section,
                "chunk_id": chunk_id,
                "text": text,
            }
        )

    return evidence


def _safe_dict(x: Any) -> dict:
    return x if isinstance(x, dict) else {}


def _summarize_target_input(target_input: dict) -> str:
    """
    UI에서 선택한 필터 요약 문자열 생성
    """
    gender = target_input.get("gender") or []
    age_bands = target_input.get("age_bands") or []
    skin_types = target_input.get("skin_types") or []
    concern_keywords = target_input.get("concern_keywords") or []

    parts = []
    if gender:
        parts.append(f"gender={gender}")
    if age_bands:
        parts.append(f"age_bands={age_bands}")
    if skin_types:
        parts.append(f"skin_types={skin_types}")
    if concern_keywords:
        parts.append(f"concern_keywords={concern_keywords}")

    return " / ".join(parts) if parts else "NO_FILTERS(전체 대상)"


def node_load_brief(state: CRMState) -> CRMState:
    repo = _repo()
    try:
        run_id = state["run_id"]
        run = repo.get_run(run_id)
        if not run:
            raise RuntimeError(f"run_id not found: {run_id}")

        brief_h = repo.get_latest_handoff(run_id, ST_BRIEF)
        brief = brief_h["payload_json"] if brief_h else run.get("brief_json", {"goal": run.get("campaign_goal")})

        channel = state.get("channel") or run.get("channel") or "PUSH"
        tone = state.get("tone") or "amoremall"

        # ✅ app.py에서 저장한 TARGET_INPUT / TARGET_AUDIENCE도 같이 로드(있으면)
        ti_h = repo.get_latest_handoff(run_id, ST_TARGET_INPUT)
        ta_h = repo.get_latest_handoff(run_id, ST_TARGET_AUDIENCE)
        target_input = ti_h["payload_json"] if ti_h else {}
        target_audience = ta_h["payload_json"] if ta_h else {}

        return {
            **state,
            "brief": brief,
            "channel": channel,
            "tone": tone,
            "target_input": _safe_dict(target_input),
            "target_audience": _safe_dict(target_audience),
        }
    finally:
        _close_repo(repo)


def node_targeting(state: CRMState) -> CRMState:
    """
    ✅ 변경 핵심
    - app.py에서 저장한 TARGET_INPUT / TARGET_AUDIENCE를 읽어
      workflow가 저장하는 TARGET payload에 합친다.
    - 기존 build_target(repo.db, brief...)는 그대로 호출하되,
      결과를 "base_target"로 두고 확장 필드를 merge한다.
    """
    repo = _repo()
    try:
        run_id = state["run_id"]
        brief = state.get("brief") or {}
        channel = state.get("channel") or "PUSH"
        tone = state.get("tone") or "amoremall"

        target_input = _safe_dict(state.get("target_input") or {})
        target_audience = _safe_dict(state.get("target_audience") or {})

        # 기존 로직 유지(안 깨지게)
        base_target = build_target(repo.db, brief=brief, channel=channel, tone=tone)
        base_target = _safe_dict(base_target)

        # app.py가 만든 audience(카운트/user_ids/키워드 매칭 결과)에서 핵심만 뽑기
        resolved = _safe_dict(target_audience.get("resolved") or {})
        audience_count = int(target_audience.get("count") or 0)
        audience_user_ids = target_audience.get("user_ids") or []
        audience_sample = target_audience.get("sample") or []

        # 확장 TARGET payload
        target = {
            **base_target,
            "target_input": target_input,  # 원본 필터(F/M, age_bands, skin_types, concern_keywords)
            "audience": {
                "count": audience_count,
                "user_ids": audience_user_ids,
                "sample": audience_sample,
                "resolved": resolved,  # 키워드→카테고리→DB concern code 변환 결과
            },
            # base_target에 summary/target_query가 있어도 덮어써도 괜찮게 별도 필드로 유지
            "target_input_summary": _summarize_target_input(target_input),
        }

        repo.create_handoff(run_id, ST_TARGET, target)
        repo.update_run(run_id, channel=channel, step_id="S2_TARGET")

        return {**state, "target": target}
    finally:
        _close_repo(repo)


def node_rag(state: CRMState) -> CRMState:
    """
    ✅ Template Agent 철학 반영:
    - Template Agent는 product/offer를 결정하지 않음 (슬롯 유지)
    - RAG는 goal + channel + tone + target 중심으로
      브랜드가이드/채널정책/컴플라이언스/베스트프랙티스 근거를 찾음

    ✅ 변경:
    - TARGET에 들어간 target_input_summary / audience.resolved(키워드 매칭) / audience.count를 query에 포함
    - retrieved.matches를 evidence로 저장해 DB handoff에서 근거 추적 가능
    """
    repo = _repo()
    try:
        run_id = state["run_id"]
        brief = state.get("brief") or {}
        target = state.get("target") or {}
        channel = state.get("channel") or "PUSH"
        tone = state.get("tone") or "amoremall"

        goal = brief.get("goal", "") or brief.get("campaign_goal", "")

        target_query = target.get("target_query", {}) or {}     # base_target가 만든 값(있으면)
        target_summary = target.get("summary", "") or ""        # base_target가 만든 값(있으면)
        target_input_summary = target.get("target_input_summary", "") or ""
        audience = _safe_dict(target.get("audience") or {})
        audience_count = audience.get("count", 0)
        resolved = _safe_dict(audience.get("resolved") or {})

        query = (
            "너는 CRM 마케터/카피라이팅 어시스턴트다.\n"
            "아래 조건에 맞는 메시지 템플릿을 만들 때 참고할 근거를 찾아라.\n\n"
            f"[캠페인 목적]\n- {goal}\n\n"
            f"[채널/톤]\n- channel={channel}\n- tone={tone}\n\n"
            f"[타겟]\n"
            f"- base_target_query={target_query}\n"
            f"- base_target_summary={target_summary}\n"
            f"- selected_filters={target_input_summary}\n"
            f"- audience_count={audience_count}\n"
            f"- concern_mapping(keywords->categories->db_codes)={resolved}\n\n"
            "[요청]\n"
            "- 브랜드 가이드(톤/문장 규칙)\n"
            "- 채널 정책(길이/구성/CTA 규칙)\n"
            "- 컴플라이언스(금지 표현/완곡 표현)\n"
            "- 유사 캠페인 포맷/베스트 프랙티스\n"
            "위 항목에 대한 근거 문장을 찾아 요약해줘.\n"
            "주의: 상품/혜택/가격은 확정하지 말고 슬롯으로 남기는 방향의 가이드만 찾아라."
        )

        retriever = RagRetriever()
        retrieved = retriever.retrieve(query=query, filters=None, top_k=10)

        # (1) LLM에 넣을 요약 컨텍스트
        context = build_context_text(retrieved, max_each=3)

        # (2) DB에 남길 근거
        evidence = _build_rag_evidence(retrieved, max_each_source=3, max_text_chars=800)

        rag_payload = {
            "query": query,
            "top_k": 10,
            "channel": channel,
            "tone": tone,
            "goal": goal,

            "base_target_query": target_query,
            "base_target_summary": target_summary,
            "target_input_summary": target_input_summary,
            "audience_count": audience_count,
            "concern_mapping": resolved,

            "evidence": evidence,
            "context": context,
        }

        repo.create_handoff(run_id, ST_RAG, rag_payload)
        repo.update_run(run_id, step_id="S3_RAG")
        return {**state, "rag": rag_payload}
    finally:
        _close_repo(repo)


def node_candidates(state: CRMState) -> CRMState:
    repo = _repo()
    try:
        run_id = state["run_id"]
        brief = state.get("brief") or {}
        rag = state.get("rag") or {}
        channel = state.get("channel") or "PUSH"
        tone = state.get("tone") or "amoremall"

        if generate_template_candidates is None:
            candidates = {
                "candidates": [
                    {
                        "template_id": "T001",
                        "title": "기본 포맷",
                        "body_with_slots": "안녕하세요 {customer_name}님 :) {product_name} 소식이에요.\n{offer}\n👉 {cta}",
                    },
                    {
                        "template_id": "T002",
                        "title": "친근 톤",
                        "body_with_slots": "{customer_name}님 :) 반가워요!\n{product_name} 관련 안내예요.\n{offer}\n👉 지금 확인: {cta}",
                    },
                ]
            }
        else:
            candidates = generate_template_candidates(
                brief=brief,
                channel=channel,
                tone=tone,
                rag_context=rag.get("context", ""),
            )

        repo.create_handoff(run_id, ST_TEMPLATE_CANDIDATES, candidates)
        repo.update_run(run_id, step_id="S4_CANDS")
        return {**state, "candidates": candidates}
    finally:
        _close_repo(repo)


def node_compliance(state: CRMState) -> CRMState:
    repo = _repo()
    try:
        run_id = state["run_id"]
        cands = (state.get("candidates") or {}).get("candidates", [])

        if validate_candidates is None:
            results = []
            for c in cands:
                body = c.get("body_with_slots", "")
                status = "PASS"
                reasons = []
                if "100% 효과" in body or "완치" in body:
                    status = "FAIL"
                    reasons.append("과장/확정 표현 가능성")
                results.append({"template_id": c.get("template_id"), "status": status, "reasons": reasons})
            compliance = {"results": results}
        else:
            compliance = validate_candidates(cands)

        repo.create_handoff(run_id, ST_COMPLIANCE, compliance)
        repo.update_run(run_id, step_id="S5_COMP")
        return {**state, "compliance": compliance}
    finally:
        _close_repo(repo)


def node_execute(state: CRMState) -> CRMState:
    """
    (옵션) 실행 에이전트 단계
    - 현재 Template Agent MVP에서는 Step2까지만 쓰지만,
      run_with_selection() 경로에서 필요할 수 있어 유지.
    - ✅ TARGET의 audience.user_ids를 execution에 넘기고 싶으면,
      execution_agent.generate_final_message 쪽 시그니처에서 받을 수 있게 확장하면 됨.
    """
    repo = _repo()
    try:
        run_id = state["run_id"]
        brief = state.get("brief") or {}
        rag = state.get("rag") or {}
        target = state.get("target") or {}
        audience = _safe_dict((target.get("audience") or {}))

        selected = state.get("selected_template")
        if not selected:
            h = repo.get_latest_handoff(run_id, ST_SELECTED_TEMPLATE)
            if not h:
                raise RuntimeError("selected_template missing (state/DB 모두 없음)")
            selected = h["payload_json"]

        if generate_final_message is None:
            final_text = (selected.get("body_with_slots") or "").format(
                customer_name="{customer_name}",
                product_name="{product_name}",
                offer="{offer}",
                cta="{cta}",
            )
            result = {
                "final_message": final_text,
                "used_template_id": selected.get("template_id"),
                "rag_used": rag.get("context", "")[:1500],
                "audience_count": audience.get("count", 0),
            }
        else:
            # ✅ 필요하면 generate_final_message에 target/audience까지 넘기도록 확장 가능
            result = generate_final_message(
                brief=brief,
                selected_template=selected,
                rag_context=rag.get("context", ""),
                # audience=audience,  # <- execution_agent가 받게 바꾸면 여기 주석 해제
            )

        repo.create_handoff(run_id, ST_EXECUTION_RESULT, result)

        repo.update_run(
            run_id,
            step_id="S6_EXEC",
            candidate_id=(selected.get("template_id") or "")[:16],
            rendered_text=result.get("final_message", ""),
        )
        return {**state, "execution_result": result}
    finally:
        _close_repo(repo)


def route_after_compliance(state: CRMState) -> str:
    if state.get("selected_template"):
        return "stage_execute"
    return END


def build_graph():
    g = StateGraph(CRMState)

    g.add_node("stage_load_brief", node_load_brief)
    g.add_node("stage_target", node_targeting)
    g.add_node("stage_rag", node_rag)
    g.add_node("stage_candidates", node_candidates)
    g.add_node("stage_compliance", node_compliance)
    g.add_node("stage_execute", node_execute)

    g.set_entry_point("stage_load_brief")
    g.add_edge("stage_load_brief", "stage_target")
    g.add_edge("stage_target", "stage_rag")
    g.add_edge("stage_rag", "stage_candidates")
    g.add_edge("stage_candidates", "stage_compliance")

    g.add_conditional_edges(
        "stage_compliance",
        route_after_compliance,
        {
            "stage_execute": "stage_execute",
            END: END,
        },
    )
    g.add_edge("stage_execute", END)

    return g.compile()


GRAPH = build_graph()


def run_until_candidates(run_id: str, channel: str, tone: str) -> Dict[str, Any]:
    init_state: CRMState = {"run_id": run_id, "channel": channel, "tone": tone}
    return GRAPH.invoke(init_state)


def run_with_selection(run_id: str, selected_template: dict) -> Dict[str, Any]:
    repo = _repo()
    try:
        repo.create_handoff(run_id, ST_SELECTED_TEMPLATE, selected_template)
        repo.update_run(run_id, step_id="S6_EXEC", candidate_id=(selected_template.get("template_id") or "")[:16])
    finally:
        _close_repo(repo)

    init_state: CRMState = {"run_id": run_id, "selected_template": selected_template}
    return GRAPH.invoke(init_state)
