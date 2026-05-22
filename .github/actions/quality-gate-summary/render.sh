#!/usr/bin/env bash
# Renders the Skyline Quality Gate Markdown summary into:
#   * $GITHUB_STEP_SUMMARY
#   * $GITHUB_WORKSPACE/quality-gate-comment.md  (consumed by the sticky PR comment step)
#
# Step outputs written to $GITHUB_OUTPUT:
#   status       : 'passed' | 'failed'
#   comment-file : absolute path to the rendered Markdown file
#
# Inputs are passed via env: by action.yml (never interpolated inline). See action.yml
# for the authoritative list. All env vars below are expected to exist (may be empty).
set -u

icon() {
  case "$1" in
    pass) echo "✅" ;;
    fail) echo "❌" ;;
    warn) echo "⚠️" ;;
    skip) echo "➖" ;;
  esac
}

is_dependabot="false"
if [ "$DEPENDABOT_BYPASS" = "true" ] && [ "$GH_ACTOR" = "dependabot[bot]" ]; then
  is_dependabot="true"
fi

overall_failed="false"

# --- Unit tests row ---------------------------------------------------------
case "$UNIT_TESTS_OUTCOME" in
  success)
    ut_icon=$(icon pass); ut_detail="All tests passed" ;;
  skipped|"")
    ut_icon=$(icon skip); ut_detail="Skipped" ;;
  *)
    ut_icon=$(icon fail); ut_detail="One or more tests failed"
    overall_failed="true" ;;
esac

# --- SonarCloud row ---------------------------------------------------------
# sonarsource/sonarqube-quality-gate-action emits: PASSED | FAILED | WARN | (empty).
# The legacy `OK` value from older Sonar actions is accepted as a synonym for PASSED.
render_sonar="false"
if [ -n "$SONAR_OUTCOME" ] || [ -n "$SONAR_STATUS" ]; then
  render_sonar="true"
  case "$SONAR_STATUS" in
    OK|PASSED)
      sc_icon=$(icon pass); sc_detail="Quality gate passed" ;;
    FAILED)
      if [ "$is_dependabot" = "true" ]; then
        sc_icon=$(icon warn); sc_detail="Code analysis quality gate failed (ignored for dependabot)"
      else
        sc_icon=$(icon fail); sc_detail="Code analysis quality gate failed"
        overall_failed="true"
      fi
      ;;
    WARN)
      sc_icon=$(icon warn); sc_detail="Code analysis quality gate passed with warnings" ;;
    *)
      if [ "$SONAR_OUTCOME" = "failure" ]; then
        sc_icon=$(icon warn); sc_detail="Could not retrieve SonarCloud quality gate status (ignored)"
      else
        sc_icon=$(icon skip); sc_detail="No SonarCloud status available"
      fi
      ;;
  esac
fi

# --- Validator row ----------------------------------------------------------
render_validator="false"
has_state_file="false"
if [ -n "$VALIDATOR_OUTCOME" ] || { [ -n "$VALIDATOR_STATE_FILE" ] && [ -f "$VALIDATOR_STATE_FILE" ]; }; then
  render_validator="true"
fi

if [ "$render_validator" = "true" ]; then
  if [ -n "$VALIDATOR_STATE_FILE" ] && [ -f "$VALIDATOR_STATE_FILE" ]; then
    has_state_file="true"
    v_status=$(jq -r '.status // ""' "$VALIDATOR_STATE_FILE")
    v_mode=$(jq -r '.mode // ""' "$VALIDATOR_STATE_FILE")
    v_version=$(jq -r '.version // ""' "$VALIDATOR_STATE_FILE")
    v_hasPrev=$(jq -r '.hasPrevious // false' "$VALIDATOR_STATE_FILE")
    v_hasCurXml=$(jq -r '.hasCurrentXml // false' "$VALIDATOR_STATE_FILE")
    v_x=$(jq -r '.x // ""' "$VALIDATOR_STATE_FILE")
    v_curC=$(jq -r '.current.critical // 0' "$VALIDATOR_STATE_FILE")
    v_curM=$(jq -r '.current.major // 0' "$VALIDATOR_STATE_FILE")
    v_curMi=$(jq -r '.current.minor // 0' "$VALIDATOR_STATE_FILE")
    v_solC=$(jq -r '.currentSolution.critical // 0' "$VALIDATOR_STATE_FILE")
    v_solM=$(jq -r '.currentSolution.major // 0' "$VALIDATOR_STATE_FILE")
    v_solMi=$(jq -r '.currentSolution.minor // 0' "$VALIDATOR_STATE_FILE")
    v_prevC=$(jq -r '.previous.critical // 0' "$VALIDATOR_STATE_FILE")
    v_prevM=$(jq -r '.previous.major // 0' "$VALIDATOR_STATE_FILE")
    v_prevMi=$(jq -r '.previous.minor // 0' "$VALIDATOR_STATE_FILE")
    v_prevVer=$(jq -r '.previous.version // ""' "$VALIDATOR_STATE_FILE")
    v_cmpIssues=$(jq -r '.compareIssueCount // 0' "$VALIDATOR_STATE_FILE")

    if [ "$v_status" = "passed" ]; then
      vg_icon=$(icon pass); vg_detail="Validator quality gate passed"
    elif [ "$v_mode" = "missing-results" ]; then
      vg_icon=$(icon fail); vg_detail="Validator quality gate failed - validation did not produce results"
      overall_failed="true"
    elif [ "$v_mode" = "missing-compare" ]; then
      vg_icon=$(icon fail); vg_detail="Validator quality gate failed - compare results missing"
      overall_failed="true"
    else
      vg_icon=$(icon fail); vg_detail="Validator quality gate failed"
      overall_failed="true"
    fi
  else
    # No state file: rely on the outcome only.
    case "$VALIDATOR_OUTCOME" in
      success)
        vg_icon=$(icon pass); vg_detail="Validator quality gate passed" ;;
      failure)
        vg_icon=$(icon fail); vg_detail="Validator quality gate failed"
        overall_failed="true" ;;
      *)
        vg_icon=$(icon warn); vg_detail="Validator quality gate did not run" ;;
    esac
  fi
fi

# --- Overall status ---------------------------------------------------------
if [ "$overall_failed" = "true" ]; then
  overall_icon=$(icon fail); overall_text="**Failed**"; final_status="failed"
else
  overall_icon=$(icon pass); overall_text="**Passed**"; final_status="passed"
fi

comment_file="${GITHUB_WORKSPACE}/quality-gate-comment.md"
{
  echo "<!-- ${COMMENT_HEADER} -->"
  echo "## Skyline Quality Gate: $overall_icon $overall_text"
  echo ""
  echo "| Sub-gate | Status | Summary |"
  echo "| --- | :---: | --- |"
  echo "| Unit Tests | $ut_icon | $ut_detail |"
  if [ "$render_sonar" = "true" ]; then
    echo "| SonarCloud | $sc_icon | $sc_detail |"
  fi
  if [ "$render_validator" = "true" ]; then
    echo "| Validator | $vg_icon | $vg_detail |"
  fi
  echo ""

  if [ "$has_state_file" = "true" ]; then
    if [ "$v_mode" = "missing-results" ]; then
      echo "**Validator details:** validation did not produce results (validate step failed)."
      echo ""
    elif [ "$v_mode" = "missing-compare" ]; then
      echo "**Validator details** (compare results missing - version-based rules not evaluated):"
      echo ""
      echo "| | Critical | Major | Minor |"
      echo "| --- | :---: | :---: | :---: |"
      echo "| Current (solution) | $v_solC | $v_solM | $v_solMi |"
      echo ""
    else
      prev_label="Compare - Previous (XML)"
      if [ -n "$v_prevVer" ]; then
        prev_label="Compare - Previous v$v_prevVer (XML)"
      fi

      # Compute red+bold markers for cells that caused the gate to fail.
      # Uses inline LaTeX color which GitHub renders red+bold in summaries and PR comments.
      red() { printf '%s' "**\$\color{red}{$1}\$**"; }

      # Solution row coloring (only meaningful in initial mode - gate runs on these counts).
      sol_c_cell="$v_solC"; sol_m_cell="$v_solM"; sol_mi_cell="$v_solMi"
      if [ "$v_mode" = "initial" ]; then
        [ "$v_solC"  -gt 0 ] 2>/dev/null && sol_c_cell=$(red "$v_solC")
        [ "$v_solM"  -gt 0 ] 2>/dev/null && sol_m_cell=$(red "$v_solM")
        [ "$v_solMi" -gt 0 ] 2>/dev/null && sol_mi_cell=$(red "$v_solMi")
      fi

      # XML-current row coloring (regular mode with previous - gate runs on these counts).
      cur_c_cell="$v_curC"; cur_m_cell="$v_curM"; cur_mi_cell="$v_curMi"
      if [ "$v_mode" = "regular" ] && [ "$v_hasCurXml" = "true" ] && [ "$v_hasPrev" = "true" ]; then
        # Critical must be 0.
        [ "$v_curC" -gt 0 ] 2>/dev/null && cur_c_cell=$(red "$v_curC")
        # Major: cur.Major <= max(0, prev.Major - X)
        major_target=$(( v_prevM - v_x ))
        [ "$major_target" -lt 0 ] && major_target=0
        [ "$v_curM" -gt "$major_target" ] 2>/dev/null && cur_m_cell=$(red "$v_curM")
        # Minor: depends on cur.Major
        if [ "$v_curM" -gt 0 ] 2>/dev/null; then
          [ "$v_curMi" -gt "$v_prevMi" ] 2>/dev/null && cur_mi_cell=$(red "$v_curMi")
        else
          minor_target=$(( v_prevMi - v_x ))
          [ "$minor_target" -lt 0 ] && minor_target=0
          [ "$v_curMi" -gt "$minor_target" ] 2>/dev/null && cur_mi_cell=$(red "$v_curMi")
        fi
      fi

      echo "**Validator details** (version \`$v_version\`, mode \`$v_mode\`):"
      echo ""
      echo "| | Critical | Major | Minor |"
      echo "| --- | :---: | :---: | :---: |"
      echo "| Current (solution) | $sol_c_cell | $sol_m_cell | $sol_mi_cell |"
      if [ "$v_hasCurXml" = "true" ] && [ "$v_hasPrev" = "true" ]; then
        echo "| Compare - Current (XML) | $cur_c_cell | $cur_m_cell | $cur_mi_cell |"
      fi
      if [ "$v_hasPrev" = "true" ]; then
        echo "| $prev_label | $v_prevC | $v_prevM | $v_prevMi |"
      fi
      echo ""
      echo "Major change checker issues (compare): **$v_cmpIssues**"
      if [ "$v_hasCurXml" = "true" ] && [ "$v_hasPrev" = "true" ]; then
        echo ""
        echo "_Delta rules are evaluated on the XML-based 'Compare' rows (same scope as previous) so solution-only checks don't skew the comparison. The solution-based counts are shown for reference._"
      fi
      echo ""
    fi
    failure_count=$(jq -r '(.failures | length) // 0' "$VALIDATOR_STATE_FILE")
    if [ "${failure_count:-0}" -gt 0 ]; then
      echo "**Validator failure reasons:**"
      jq -r '.failures[] | "- " + .' "$VALIDATOR_STATE_FILE"
      echo ""
    fi
  fi

  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${GITHUB_EVENT_NAME:-}" = "pull_request_target" ]; then
    echo "_See the [Actions run]($RUN_URL) for full logs._"
  fi
} > "$comment_file"

cat "$comment_file" >> "$GITHUB_STEP_SUMMARY"
{
  echo "status=$final_status"
  echo "comment-file=$comment_file"
} >> "$GITHUB_OUTPUT"
