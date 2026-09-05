{
  agentSkills = [
    {
      agent = "architect";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      agent = "architect";
      skill = "description-writing";
      activation = "dynamic";
    }
    {
      agent = "architect";
      skill = "impact-analysis";
      activation = "dynamic";
    }
    {
      agent = "architect";
      skill = "interface-design";
      activation = "dynamic";
    }
    {
      agent = "architect";
      skill = "module-design";
      activation = "dynamic";
    }
    {
      agent = "architect";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      agent = "architect";
      skill = "web-research";
      activation = "dynamic";
    }
    {
      agent = "designer";
      skill = "browser-operation";
      activation = "dynamic";
    }
    {
      agent = "designer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      agent = "designer";
      skill = "ui-design";
      activation = "required";
    }
    {
      agent = "explorer";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      agent = "explorer";
      skill = "repository-research";
      activation = "required";
    }
    {
      agent = "implementer";
      skill = "browser-operation";
      activation = "dynamic";
    }
    {
      agent = "implementer";
      skill = "code-design";
      activation = "dynamic";
    }
    {
      agent = "implementer";
      skill = "comment-writing";
      activation = "dynamic";
    }
    {
      agent = "implementer";
      skill = "documentation-writing";
      activation = "dynamic";
    }
    {
      agent = "implementer";
      skill = "refactoring";
      activation = "dynamic";
    }
    {
      agent = "implementer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      agent = "implementer";
      skill = "security-review";
      activation = "dynamic";
    }

    {
      agent = "implementer";
      skill = "tdd";
      activation = "dynamic";
    }
    {
      agent = "planner";
      skill = "dependency-analysis";
      activation = "dynamic";
    }
    {
      agent = "planner";
      skill = "impact-analysis";
      activation = "dynamic";
    }
    {
      agent = "planner";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      agent = "planner";
      skill = "web-research";
      activation = "dynamic";
    }
    {
      agent = "reviewer";
      skill = "code-review";
      activation = "required";
    }
    {
      agent = "reviewer";
      skill = "github-operations";
      activation = "dynamic";
    }
    {
      agent = "reviewer";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      agent = "security";
      skill = "github-operations";
      activation = "dynamic";
    }
    {
      agent = "security";
      skill = "repository-research";
      activation = "dynamic";
    }
    {
      agent = "security";
      skill = "security-review";
      activation = "required";
    }
  ];

  agentHandoffs = [
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
