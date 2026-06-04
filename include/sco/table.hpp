#pragma once

#include <iosfwd>
#include <string>
#include <vector>

namespace sco {

enum class TableAlign {
    Left,
    Right,
};

struct TableColumn {
    std::string header;
    TableAlign align = TableAlign::Left;
};

struct TableOptions {
    bool leading_blank_line = true;
    bool trailing_blank_line = true;
    bool separator = true;
    std::size_t indent = 0;
    std::size_t column_spacing = 1;
};

void write_table(
    std::ostream& out,
    const std::vector<TableColumn>& columns,
    const std::vector<std::vector<std::string>>& rows,
    const TableOptions& options = {});

void write_table(
    std::ostream& out,
    const std::vector<std::string>& headers,
    const std::vector<std::vector<std::string>>& rows,
    const TableOptions& options = {});

} // namespace sco
