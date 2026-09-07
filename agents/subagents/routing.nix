{
  subagentSkills = [
    {
      subagent = "architect";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "description-writing";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "impact-analysis";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "interface-design";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "module-design";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "standard-apply";
      activation = "dynamic";
    }
    {
      subagent = "architect";
      skill = "web-research";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "browser-operation";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "designer";
      skill = "ui-design";
      activation = "required";
    }
    {
      subagent = "explorer";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      subagent = "explorer";
      skill = "repository-research";
      activation = "required";
    }
    {
      subagent = "implementer";
      skill = "browser-operation";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "code-design";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "comment-writing";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "documentation-writing";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "refactoring-implementation";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "security-review";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "standard-apply";
      activation = "dynamic";
    }
    {
      subagent = "implementer";
      skill = "tdd-implementation";
      activation = "dynamic";
    }
    {
      subagent = "planner";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      subagent = "planner";
      skill = "impact-analysis";
      activation = "dynamic";
    }
    {
      subagent = "planner";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "planner";
      skill = "web-research";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "code-review";
      activation = "required";
    }
    {
      subagent = "reviewer";
      skill = "github-operations";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "standard-apply";
      activation = "dynamic";
    }
    {
      subagent = "reviewer";
      skill = "standard-conformance";
      activation = "dynamic";
    }
    {
      subagent = "security";
      skill = "github-operations";
      activation = "dynamic";
    }
    {
      subagent = "security";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      subagent = "security";
      skill = "security-review";
      activation = "required";
    }
  ];

  subagentHandoffs = [
    {
      from = "architect";
      to = "implementer";
      artifact = "accepted-contract";
    }
    {
      from = "architect";
      to = "planner";
      artifact = "accepted-decision-constraints";
    }
    {
      from = "designer";
      to = "implementer";
      artifact = "accepted-ui-brief";
    }
    {
      from = "designer";
      to = "planner";
      artifact = "ui-brief-dependencies";
    }
    {
      from = "explorer";
      to = "architect";
      artifact = "dependency-facts";
    }
    {
      from = "explorer";
      to = "planner";
      artifact = "repository-evidence";
    }
    {
      from = "implementer";
      to = "reviewer";
      artifact = "verified-diff";
    }
    {
      from = "planner";
      to = "architect";
      artifact = "unresolved-design-decision";
    }
    {
      from = "planner";
      to = "implementer";
      artifact = "accepted-plan";
    }
    {
      from = "reviewer";
      to = "implementer";
      artifact = "evidence-backed-findings";
    }
    {
      from = "reviewer";
      to = "security";
      artifact = "security-candidate-scope";
    }
    {
      from = "security";
      to = "implementer";
      artifact = "validated-finding-attack-path";
    }
  ];
}
